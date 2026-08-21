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
    let networkSelection: SteamNetworkCompatibilitySelection
    let audioInputSelection: SteamAudioInputSelection
    let synchronizationSelection: WineSynchronizationSelection
    let videoMemorySelection: SteamVideoMemorySelection
    let gameModePolicy: SteamGameModeLaunchPolicy
    let fpsCursorPolicy: FPSCursorCapturePolicy
    let controllerPolicy: ControllerCompatibilityPolicy
    let keyboardMapping: KeyboardMappingPreference
}

private struct SavedStandardSteamLaunchConfiguration {
    let snapshot: SteamLaunchConfigurationSnapshot
    let selection: SteamLaunchConfigurationProductSelection
}

enum StandardSteamLaunchReservationFailurePolicy {
    static let windowsExecutableReservedLocalizationKey =
        "다른 EXE 실행이 끝날 때까지 기다리세요."

    static func preflightBlockerLocalizationKey(
        isWindowsExecutableLaunchReserved: Bool
    ) -> String? {
        guard isWindowsExecutableLaunchReserved else { return nil }
        return windowsExecutableReservedLocalizationKey
    }

    static func localizationKey(
        for error: NavigationStableSessionOwnershipError
    ) -> String {
        switch error {
        case .transitionInProgress:
            "호환성 Steam 세션 작업이 이미 진행 중입니다."
        case .sessionAlreadyActive:
            "기존 호환성 Steam 세션을 먼저 종료하고 기준 상태 복원을 확인하세요."
        case .noActiveSession:
            "종료할 활성 호환성 Steam 세션이 없습니다."
        case .preparationNotInProgress:
            "호환성 Steam 세션 준비 상태가 올바르지 않습니다."
        case .standardSteamLaunchReserved:
            "일반 Steam 실행 전환이 진행 중입니다."
        case .standardSteamLaunchReservationMismatch:
            "일반 Steam 실행 전환 중 호환성 세션 상태가 변경되었습니다."
        case .standardSteamLaunchNotReady:
            "호환성 세션 복원 또는 다른 프리픽스 작업이 끝나지 않았습니다."
        case .windowsExecutableLaunchReserved:
            windowsExecutableReservedLocalizationKey
        case .windowsExecutableLaunchBlockedByCompatibilitySession:
            "활성 호환성 Steam 세션을 먼저 종료하세요."
        case .windowsExecutableLaunchBlockedByCompatibilityTransition:
            "호환성 Steam 세션 전환이 끝날 때까지 기다리세요."
        case .windowsExecutableLaunchNotReady:
            "Steam 실행 또는 다른 프리픽스 작업이 끝날 때까지 기다리세요."
        }
    }
}

private enum StandardLaunchConfigurationRestoreState: Equatable {
    case pending
    case restoring
    case completed
}

private struct SteamLaunchReadinessSnapshot: Equatable {
    static let pending = Self(
        taskID: "",
        steamLaunchBlocker: nil,
        selectedRendererLaunchBlocker: nil,
        rendererAvailabilityBySelection: [:]
    )

    let taskID: String
    let steamLaunchBlocker: String?
    let selectedRendererLaunchBlocker: String?
    let rendererAvailabilityBySelection:
        [SteamRendererPolicySelection: SteamRendererPolicyAvailability]
}

private struct SteamLaunchRuntimeInspection: Sendable {
    let canLaunchWindowsSteam: Bool
    let steamLaunchMessageKey: String
    let rendererAvailabilityBySelection:
        [SteamRendererPolicySelection: SteamRendererPolicyAvailability]
}

private actor SteamLaunchReadinessInspectionCoordinator {
    func inspect(
        capability: WindowsRuntimeCapability,
        selectionRawValue: String?
    ) -> SteamLaunchRuntimeInspection? {
        guard !Task.isCancelled else { return nil }

        let steamVerification = SteamClientCompatibilityVerifier.verify(
            capability: capability
        )
        _ = selectionRawValue
        let rendererAvailabilityBySelection = Dictionary(
            uniqueKeysWithValues: SteamRendererPolicySelection.allCases.map {
                selection in
                (
                    selection,
                    selection.forcedPreference?.availability(in: capability) ??
                        .unavailable()
                )
            }
        )
        guard !Task.isCancelled else { return nil }

        return SteamLaunchRuntimeInspection(
            canLaunchWindowsSteam: steamVerification.canLaunchWindowsSteam,
            steamLaunchMessageKey: steamVerification.userMessage,
            rendererAvailabilityBySelection: rendererAvailabilityBySelection
        )
    }
}

private let steamLaunchReadinessInspectionCoordinator =
    SteamLaunchReadinessInspectionCoordinator()

struct SteamLaunchView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \SteamGameRecord.name) private var games: [SteamGameRecord]
    @Query(sort: \SteamStorageMountRecord.path) private var steamStorageMounts: [SteamStorageMountRecord]
    @Query(sort: \PrefixRecord.displayName) private var prefixes: [PrefixRecord]
    @Query private var launchRecords: [LaunchRecord]
    @State private var steamReferencePendingRemoval: SteamGameRecord?
    @State private var steamStoragePendingRemoval: SteamStorageMountRecord?
    @State private var isShowingSteamPrefixRebuildConfirmation = false
    @State private var isRebuildingSteamPrefix = false
    @State private var steamInstallerPersistenceWarningForRebuild: String?
    @State private var selectedWorkspace: SteamWorkspace = .launch
    @State private var selectedRendererForNextSteamLaunch: SteamRendererPolicySelection?
    @State private var selectedNetworkForNextSteamLaunch: SteamNetworkCompatibilitySelection?
    @State private var selectedAudioInputForNextSteamLaunch: SteamAudioInputSelection?
    @State private var keyboardMappingForNextSteamLaunch =
        KeyboardMappingPreference.systemDefault
    @State private var steamSessionConfigurationBeingLaunched: ActiveSteamSessionConfiguration?
    @State private var isExperimentalGameModeEnabledForNextLaunch = true
    @State private var standardLaunchDraftBase = SteamLaunchConfigurationSnapshot.standardDefault
    @State private var savedStandardLaunchConfigurationDigest: String?
    @State private var savedStandardLaunchConfigurationVersion: SteamLaunchConfigurationRecordVersion?
    @State private var standardLaunchConfigurationSaveFailed = false
    @State private var standardLaunchConfigurationErrorMessage: String?
    @State private var standardLaunchConfigurationRestoreState:
        StandardLaunchConfigurationRestoreState = .pending
    @State private var standardLaunchConfigurationRestoreIsBlocked = false
    @State private var standardLaunchConfigurationReloadIsAvailable = false
    @State private var isShowingStandardLaunchConfigurationResetConfirmation = false
    @State private var steamStorageHealthReports: [String: SteamStorageHealthReport] = [:]
    @State private var steamStorageHealthErrorMessage: String?
    @State private var steamStorageHealthRefreshGeneration = 0
    @State private var isCheckingSteamStorageHealth = false
    @State private var steamLaunchReadinessSnapshot = SteamLaunchReadinessSnapshot.pending
    let helpSection: AppSection

    private var readiness: SetupReadiness {
        appState.setupReadiness
    }

    init(helpSection: AppSection = .steamLaunch) {
        self.helpSection = helpSection
        var launchDescriptor = FetchDescriptor<LaunchRecord>(
            predicate: #Predicate {
                $0.commandKind == "launchSteam" &&
                    $0.prefixId == "prefix-steam-shared"
            },
            sortBy: [SortDescriptor(\LaunchRecord.startedAt, order: .reverse)]
        )
        launchDescriptor.fetchLimit = 1
        _launchRecords = Query(launchDescriptor)
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

    private var steamLaunchReadinessTaskID: String {
        [
            String(services.steamEnvironmentRevision),
            String(readiness.hashValue),
            appState.runtimeExecutableURL?.path ?? "runtime-unavailable",
            selectedRendererForNextSteamLaunch?.rawValue ?? "renderer-unselected",
            appState.effectiveLanguageMode.rawValue
        ].joined(separator: "#")
    }

    private var steamLaunchReadinessSnapshotIsCurrent: Bool {
        steamLaunchReadinessSnapshot.taskID == steamLaunchReadinessTaskID
    }

    private var cachedSteamLaunchBlocker: String? {
        guard steamLaunchReadinessSnapshotIsCurrent else { return nil }
        return steamLaunchReadinessSnapshot.steamLaunchBlocker
    }

    private var cachedSelectedRendererLaunchBlocker: String? {
        guard steamLaunchReadinessSnapshotIsCurrent else { return nil }
        return steamLaunchReadinessSnapshot.selectedRendererLaunchBlocker
    }

    private func cachedRendererAvailability(
        for selection: SteamRendererPolicySelection
    ) -> SteamRendererPolicyAvailability? {
        guard steamLaunchReadinessSnapshotIsCurrent else { return nil }
        return steamLaunchReadinessSnapshot
            .rendererAvailabilityBySelection[selection]
    }

    private var selectedRendererRuntimeIsUnavailableOrPending: Bool {
        guard selectedRendererForNextSteamLaunch == .vulkan else { return false }
        return cachedRendererAvailability(for: .vulkan)?.isAvailable != true
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
            await Task.yield()
            if appState.setupStage == .connectLibrary {
                selectedWorkspace = .storage
            }
            restoreStandardLaunchConfigurationOnce()
            refreshGameInputProtectionAuthorizationIfNeeded()
        }
        .task(id: steamStorageHealthTaskID) {
            guard selectedWorkspace == .storage else {
                isCheckingSteamStorageHealth = false
                return
            }
            await refreshSteamStorageHealth(taskID: steamStorageHealthTaskID)
        }
        .task(id: steamLaunchReadinessTaskID) {
            await refreshSteamLaunchReadiness(taskID: steamLaunchReadinessTaskID)
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
            appState.localized("저장된 표준 Steam 실행 구성을 초기화할까요?"),
            isPresented: $isShowingStandardLaunchConfigurationResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(appState.localized("저장된 구성 초기화"), role: .destructive) {
                resetBlockedStandardLaunchConfiguration()
            }
            Button(appState.localized("취소"), role: .cancel) {}
        } message: {
            Text(appState.localized("읽을 수 없는 표준 Steam 실행 구성 기록만 삭제하고 안전한 기본값을 편집 가능한 초안으로 불러옵니다. Steam 프리픽스, 게임 파일, 실행 기록은 변경하지 않으며 기본값은 저장 버튼이나 Steam 실행을 누르기 전까지 저장하지 않습니다."))
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
                steamLaunchPrimaryActions

                Text(appState.localized(
                    "이 화면은 모든 게임에 공통으로 사용하는 일반 Steam 실행 경로입니다. 게임별 호환성 프로필은 별도의 Steam 호환성 실행 화면에서 관리하며 이 설정을 덮어쓰지 않습니다."
                ))
                .font(.callout)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                steamLaunchConfigurationStateSummaries(palette: palette)

                Divider()

                Text(appState.localized("다음 Steam 실행 설정"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)

                manualRendererSelectionGrid(palette: palette)
                Text(
                    appState.localized(
                        selectedRendererForNextSteamLaunch?.detailKey ??
                            "이번 Steam 세션에 적용할 그래픽 백엔드 하나를 직접 선택하세요."
                    )
                )
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                if let dxvkAvailability = cachedRendererAvailability(for: .vulkan),
                   !dxvkAvailability.isAvailable,
                   let messageKey = dxvkAvailability.userMessageLocalizationKey {
                    Label(
                        appState.localized(messageKey),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
                experimentalGameModeControl(palette: palette)
                steamCompatibilitySelectionControls(palette: palette)
                standardKeyboardMappingStatus(palette: palette)
                ControllerCompatibilityPreflightPanel()

                if let standardLaunchConfigurationErrorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(standardLaunchConfigurationErrorMessage)
                            .font(.caption)
                            .foregroundStyle(palette.warning)
                            .fixedSize(horizontal: false, vertical: true)

                        if standardLaunchConfigurationRestoreIsBlocked ||
                            standardLaunchConfigurationReloadIsAvailable {
                            ThemedActionButton(
                                title: "최신 구성 다시 불러오기",
                                systemImage: "arrow.clockwise",
                                prominence: .secondary,
                                isDisabled: appState.isSteamLaunchInProgress ||
                                    services.steamPrefixLifecycleCoordinator.isBusy,
                                controlSize: .small
                            ) {
                                reloadLatestStandardLaunchConfiguration()
                            }
                            .frame(minWidth: 170, idealWidth: 220, maxWidth: 280)
                        }

                        if standardLaunchConfigurationRestoreIsBlocked,
                           savedStandardLaunchConfigurationVersion != nil {
                            ThemedActionButton(
                                title: "저장된 구성 초기화",
                                systemImage: "arrow.counterclockwise",
                                prominence: .secondary,
                                isDisabled: appState.isSteamLaunchInProgress ||
                                    services.steamPrefixLifecycleCoordinator.isBusy,
                                controlSize: .small
                            ) {
                                isShowingStandardLaunchConfigurationResetConfirmation = true
                            }
                            .frame(minWidth: 150, idealWidth: 190, maxWidth: 240)
                        }
                    }
                }

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

                if let blocker = cachedSelectedRendererLaunchBlocker {
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

    private var steamLaunchPrimaryActions: some View {
        let availability = standardLaunchAvailability
        return VStack(alignment: .leading, spacing: 8) {
            ResponsiveActionRow {
                ThemedActionButton(
                    title: "Steam 실행",
                    systemImage: "play.fill",
                    prominence: .primary,
                    isDisabled: !availability.isAvailable
                ) {
                    launchSteam()
                }
                .help(availability.message)
                .accessibilityHint(availability.message)
                ThemedActionButton(
                    title: "설정 저장",
                    systemImage: "square.and.arrow.down",
                    prominence: .secondary,
                    isDisabled: standardLaunchConfigurationSaveIsDisabled
                ) {
                    saveStandardLaunchConfigurationFromAction()
                }
                ThemedActionButton(
                    title: "저장공간 관리",
                    systemImage: "externaldrive",
                    prominence: .secondary
                ) {
                    selectedWorkspace = .storage
                }
            }

            if let disabledReason = availability.disabledReason {
                Label(disabledReason, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(disabledReason)
            }

            if gameInputProtectionAuthorizationBlockerKey != nil {
                GameInputProtectionAuthorizationPanel(
                    disablePermissionRequiredProtection:
                        disablePermissionRequiredGameInputProtection
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func steamLaunchConfigurationStateSummaries(
        palette: ForgePlayPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let steamSessionConfigurationBeingLaunched {
                steamLaunchConfigurationSummary(
                    title: appState.localized("Steam 시작 확인 중"),
                    detail: appState.localized("시작이 끝나기 전에는 이 값을 현재 Steam 세션에 적용된 것으로 표시하지 않습니다."),
                    systemImage: "clock.arrow.circlepath",
                    configuration: steamSessionConfigurationBeingLaunched,
                    accent: palette.primary,
                    palette: palette
                )
            }

            if let nextSteamLaunchDraftConfiguration {
                steamLaunchConfigurationSummary(
                    title: appState.localized(
                        standardLaunchDraftIsSaved
                            ? "다음 실행 초안 · 저장됨"
                            : "다음 실행 초안 · 저장되지 않은 변경"
                    ),
                    detail: appState.localized(
                        standardLaunchDraftIsSaved
                            ? "저장된 표준 구성이며 다음 Steam 실행에 다시 사용됩니다."
                            : "변경한 구성은 저장한 뒤에만 Steam 실행에 사용할 수 있습니다."
                    ),
                    systemImage: standardLaunchDraftIsSaved
                        ? "tray.and.arrow.down.fill"
                        : "pencil.circle",
                    configuration: nextSteamLaunchDraftConfiguration,
                    accent: cachedSelectedRendererLaunchBlocker == nil
                        ? palette.primary
                        : palette.warning,
                    palette: palette
                )
            } else {
                Text(appState.localized("저장된 Steam 실행 구성을 읽은 뒤 그래픽 백엔드, 네트워크, 오디오 입력을 모두 확인해야 Steam을 실행할 수 있습니다."))
                    .font(.caption)
                    .foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func steamLaunchConfigurationSummary(
        title: String,
        detail: String,
        systemImage: String,
        configuration: ActiveSteamSessionConfiguration,
        accent: Color,
        palette: ForgePlayPalette
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(accent)
                .frame(width: 20, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text(configurationSummaryText(configuration))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.control)
        .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius))
        .accessibilityElement(children: .combine)
    }

    private var nextSteamLaunchDraftConfiguration: ActiveSteamSessionConfiguration? {
        guard let selectedRendererForNextSteamLaunch,
              let selectedNetworkForNextSteamLaunch,
              let selectedAudioInputForNextSteamLaunch else {
            return nil
        }
        return ActiveSteamSessionConfiguration(
            rendererSelection: selectedRendererForNextSteamLaunch,
            networkSelection: selectedNetworkForNextSteamLaunch,
            audioInputSelection: selectedAudioInputForNextSteamLaunch,
            synchronizationSelection: appState.wineSynchronizationSelection,
            videoMemorySelection: appState.steamVideoMemorySelection,
            gameModePolicy: isExperimentalGameModeEnabledForNextLaunch
                ? .experimentalRequiredHost
                : .standard,
            fpsCursorPolicy: standardLaunchDraftBase.fpsCursorPolicy,
            controllerPolicy: standardLaunchDraftBase.controllerPolicy,
            keyboardMapping: keyboardMappingForNextSteamLaunch
        )
    }

    private var standardLaunchAvailability: LaunchAvailability {
        if standardLaunchConfigurationRestoreState != .completed {
            return .unavailable(
                reason: appState.localized("저장된 Steam 실행 구성을 불러오는 중입니다.")
            )
        }
        if standardLaunchConfigurationRestoreIsBlocked {
            return .unavailable(
                reason: standardLaunchConfigurationErrorMessage ?? appState.localized(
                    "저장된 Steam 실행 구성을 안전하게 다시 불러온 뒤 Steam을 실행하세요."
                )
            )
        }
        if standardLaunchConfigurationReloadIsAvailable {
            return .unavailable(
                reason: appState.localized(
                    "저장된 Steam 실행 구성을 안전하게 다시 불러온 뒤 Steam을 실행하세요."
                )
            )
        }
        if let blockerKey = gameInputProtectionAuthorizationBlockerKey {
            return .unavailable(reason: appState.localized(blockerKey))
        }
        guard selectedRendererForNextSteamLaunch != nil else {
            return .unavailable(
                reason: appState.localized(
                    "이번 Steam 실행에 사용할 그래픽 백엔드를 직접 선택하세요."
                )
            )
        }
        guard selectedNetworkForNextSteamLaunch != nil else {
            return .unavailable(
                reason: appState.localized(
                    "이번 Steam 실행에 사용할 네트워크 호환성 방식을 직접 선택하세요."
                )
            )
        }
        guard selectedAudioInputForNextSteamLaunch != nil else {
            return .unavailable(
                reason: appState.localized(
                    "이번 Steam 실행에서 오디오 입력을 끌지 켤지 직접 선택하세요."
                )
            )
        }
        guard standardKeyboardMappingIsSupported else {
            return .unavailable(
                reason: appState.localized(
                    "지원되지 않는 이전 키보드 저장 값이 있습니다. System Default로 복원한 뒤 설정을 저장하세요."
                )
            )
        }
        guard standardLaunchDraftIsSaved else {
            return .unavailable(
                reason: appState.localized(
                    "변경한 Steam 실행 구성은 저장에 성공한 뒤에만 실행할 수 있습니다."
                )
            )
        }
        if appState.isSteamLaunchInProgress {
            return .unavailable(reason: appState.localized("Steam 실행이 이미 진행 중입니다."))
        }
        if appState.steamStorageOperationMountID != nil {
            return .unavailable(
                reason: appState.localized(
                    "Steam 저장공간 연결 작업이 진행 중입니다. 완료된 뒤 다시 시도하세요."
                )
            )
        }
        if let blockerKey = StandardSteamLaunchReservationFailurePolicy
            .preflightBlockerLocalizationKey(
                isWindowsExecutableLaunchReserved: services
                    .steamCompatibilitySessionCoordinator
                    .isWindowsExecutableLaunchReserved
            ) {
            return .unavailable(reason: appState.localized(blockerKey))
        }
        switch standardSteamCompatibilitySessionHandoff {
        case .blockedByCompatibilityTransition:
            return .unavailable(
                reason: appState.localized(
                    "호환성 Steam 세션 작업이 이미 진행 중입니다."
                )
            )
        case .blockedByAnotherPrefixOperation:
            return .unavailable(
                reason: appState.localized(
                    "다른 Steam 프리픽스 작업이 이미 진행 중입니다. 완료된 뒤 다시 시도하세요."
                )
            )
        case .ready, .reconcileActiveSession:
            break
        }
        guard steamLaunchReadinessSnapshotIsCurrent else {
            return .unavailable(
                reason: appState.localized("Steam 실행 준비 상태를 확인하는 중입니다.")
            )
        }
        if let cachedSteamLaunchBlocker {
            return .unavailable(reason: cachedSteamLaunchBlocker)
        }
        if let cachedSelectedRendererLaunchBlocker {
            return .unavailable(reason: cachedSelectedRendererLaunchBlocker)
        }
        let message = standardSteamCompatibilitySessionHandoff == .reconcileActiveSession
            ? "관리 Wine 프로세스 종료와 기준 상태 복원을 확인한 뒤 일반 Steam을 실행합니다."
            : "저장된 설정과 필수 실행 준비가 확인되어 Steam을 실행할 수 있습니다."
        return .available(message: appState.localized(message))
    }

    private var gameInputProtectionAuthorizationBlockerKey: String? {
        SteamLaunchGameInputProtectionAdmissionPolicy.blockerLocalizationKey(
            policy: services.gameInputProtectionPolicyStore.snapshot(),
            authorizationStatus: services.gameInputProtectionAuthorizationStatus
        )
    }

    private func refreshGameInputProtectionAuthorizationIfNeeded() {
        guard services.gameInputProtectionPolicyStore.snapshot().requiresEventTap else {
            return
        }
        services.refreshGameInputProtectionAuthorizationStatus()
    }

    private func disablePermissionRequiredGameInputProtection() {
        let warning = appState.saveUserPreferencesAfterMutation(
            to: modelContext
        ) {
            appState.disableGameInputEventTapProtection()
        }
        guard warning == nil else { return }
        services.synchronizeGameInputProtectionPolicy(from: appState)
        appState.setNotice(
            appState.localized(
                "권한이 필요한 입력 보호를 껐습니다. Steam은 권한이 필요한 보호 없이 실행할 수 있습니다."
            ),
            kind: .success
        )
    }

    private var standardSteamCompatibilitySessionHandoff:
        StandardSteamCompatibilitySessionHandoff
    {
        let coordinator = services.steamCompatibilitySessionCoordinator
        return StandardSteamCompatibilitySessionHandoff.resolve(
            hasActiveCompatibilitySession: coordinator.hasActiveSession,
            compatibilityTransitionInProgress: coordinator.isTransitionInProgress,
            prefixLifecycleIsBusy: services.steamPrefixLifecycleCoordinator.isBusy
        )
    }

    private var standardLaunchDraftIsSaved: Bool {
        guard !standardLaunchConfigurationSaveFailed,
              !standardLaunchConfigurationReloadIsAvailable,
              let savedStandardLaunchConfigurationDigest,
              let savedStandardLaunchConfigurationVersion,
              savedStandardLaunchConfigurationDigest == savedStandardLaunchConfigurationVersion.digest else {
            return false
        }
        guard let currentSnapshot = try? currentStandardLaunchConfigurationSnapshot() else {
            return false
        }
        return currentSnapshot == standardLaunchDraftBase
    }

    private func configurationSummaryText(
        _ configuration: ActiveSteamSessionConfiguration
    ) -> String {
        appState.localizedFormat(
            "그래픽 %@ · 네트워크 %@ · 오디오 입력 %@ · 동기화 %@ · 게임 비디오 메모리 %@ · Game Mode %@ · FPS 커서 %@ · 컨트롤러 %@ · 키보드 %@",
            appState.localized(configuration.rendererSelection.labelKey),
            appState.localized(configuration.networkSelection.labelKey),
            appState.localized(configuration.audioInputSelection.labelKey),
            appState.localized(configuration.synchronizationSelection.labelKey),
            localizedVideoMemoryPolicy(configuration.videoMemorySelection),
            gameModeStateLabel(
                isEnabled: configuration.gameModePolicy == .experimentalRequiredHost
            ),
            configuration.fpsCursorPolicy.rawValue,
            configuration.controllerPolicy.rawValue,
            keyboardMappingDisplayValue(configuration.keyboardMapping)
        )
    }

    private func keyboardMappingDisplayValue(
        _ mapping: KeyboardMappingPreference
    ) -> String {
        appState.localized(
            mapping == .systemDefault
                ? "System Default"
                : "지원되지 않는 이전 저장 값"
        )
    }

    private func localizedVideoMemoryPolicy(
        _ selection: SteamVideoMemorySelection
    ) -> String {
        selection.rawValue == "automatic"
            ? appState.localized("자동")
            : appState.localized(selection.rawValue)
    }

    private func manualRendererSelectionGrid(
        palette: ForgePlayPalette
    ) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 118, maximum: 180), spacing: 6)
            ],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(SteamRendererPolicySelection.allCases) { selection in
                let isSelected = selectedRendererForNextSteamLaunch == selection
                let compactLabelKey = selection.labelKey
                let runtimeAvailability = cachedRendererAvailability(
                    for: selection
                )
                let runtimeIsUnavailableOrPending = selection == .vulkan &&
                    runtimeAvailability?.isAvailable != true
                let helpKey = runtimeAvailability?
                    .userMessageLocalizationKey ?? selection.detailKey
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
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
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
                    standardLaunchDraftControlsAreDisabled ||
                        runtimeIsUnavailableOrPending
                )
                .help(appState.localized(helpKey))
                .accessibilityLabel(appState.localized(compactLabelKey))
                .accessibilityValue(
                    appState.localized(
                        runtimeIsUnavailableOrPending
                            ? "사용할 수 없음"
                            : (isSelected ? "선택됨" : "선택되지 않음")
                    )
                )
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint(appState.localized(helpKey))
            }
        }
    }

    private func steamCompatibilitySelectionControls(
        palette: ForgePlayPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    networkCompatibilityPicker(palette: palette)
                    Divider()
                        .frame(height: 24)
                    audioInputPicker(palette: palette)
                    Divider()
                        .frame(height: 24)
                    videoMemoryPicker(palette: palette)
                }
                VStack(alignment: .leading, spacing: 6) {
                    networkCompatibilityPicker(palette: palette)
                    audioInputPicker(palette: palette)
                    videoMemoryPicker(palette: palette)
                }
            }

            Text(compatibilitySelectionDetailText)
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.control)
        .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius))
    }

    private func networkCompatibilityPicker(
        palette: ForgePlayPalette
    ) -> some View {
        HStack(spacing: 8) {
            Label(appState.localized("네트워크 (베타)"), systemImage: "network")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text)
            Spacer(minLength: 4)
            Picker(
                appState.localized("네트워크 (베타)"),
                selection: $selectedNetworkForNextSteamLaunch
            ) {
                Text(appState.localized("선택 필요"))
                    .tag(Optional<SteamNetworkCompatibilitySelection>.none)
                ForEach(SteamNetworkCompatibilitySelection.allCases) { selection in
                    Text(appState.localized(selection.labelKey))
                        .tag(Optional(selection))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(standardLaunchDraftControlsAreDisabled)
            .accessibilityHint(
                appState.localized(
                    selectedNetworkForNextSteamLaunch?.detailKey ??
                        "이번 Steam 실행의 네트워크 호환성 방식을 직접 선택하세요."
                )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func audioInputPicker(
        palette: ForgePlayPalette
    ) -> some View {
        HStack(spacing: 8) {
            Label(appState.localized("오디오 입력 (베타)"), systemImage: "mic")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text)
            Spacer(minLength: 4)
            Picker(
                appState.localized("오디오 입력 (베타)"),
                selection: $selectedAudioInputForNextSteamLaunch
            ) {
                Text(appState.localized("선택 필요"))
                    .tag(Optional<SteamAudioInputSelection>.none)
                ForEach(SteamAudioInputSelection.allCases) { selection in
                    Text(appState.localized(selection.labelKey))
                        .tag(Optional(selection))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(standardLaunchDraftControlsAreDisabled)
            .accessibilityHint(
                appState.localized(
                    selectedAudioInputForNextSteamLaunch?.detailKey ??
                        "이번 Steam 실행에서 Wine의 오디오 입력 노출 여부를 직접 선택하세요."
                )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func videoMemoryPicker(
        palette: ForgePlayPalette
    ) -> some View {
        HStack(spacing: 8) {
            Label(appState.localized("게임 비디오 메모리 (베타)"), systemImage: "memorychip")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text)
            Spacer(minLength: 4)
            Picker(
                appState.localized("게임 비디오 메모리 (베타)"),
                selection: Binding(
                    get: { appState.steamVideoMemorySelection },
                    set: { appState.steamVideoMemorySelection = $0 }
                )
            ) {
                ForEach(SteamVideoMemorySelection.allCases) { selection in
                    Text(appState.localized(selection.labelKey))
                        .tag(selection)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(standardLaunchDraftControlsAreDisabled)
            .accessibilityValue(
                appState.localized(appState.steamVideoMemorySelection.labelKey)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compatibilitySelectionDetailText: String {
        switch (
            selectedNetworkForNextSteamLaunch,
            selectedAudioInputForNextSteamLaunch
        ) {
        case let (network?, audio?):
            return [
                appState.localized(network.detailKey),
                appState.localized(audio.detailKey)
            ].joined(separator: " ")
        case (nil, nil):
            return appState.localized(
                "표준 네트워크도 자동 선택하지 않습니다. 네트워크 방식과 오디오 입력을 각각 직접 선택하세요."
            )
        case (nil, _):
            return appState.localized(
                "이번 Steam 실행의 네트워크 호환성 방식을 직접 선택하세요."
            )
        case (_, nil):
            return appState.localized(
                "이번 Steam 실행에서 Wine의 오디오 입력 노출 여부를 직접 선택하세요."
            )
        }
    }

    private var standardKeyboardMappingIsSupported: Bool {
        keyboardMappingForNextSteamLaunch == .systemDefault
    }

    private func standardKeyboardMappingStatus(
        palette: ForgePlayPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(appState.localized("키보드 입력"), systemImage: "keyboard")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
                Spacer(minLength: 8)
                Text(keyboardMappingDisplayValue(keyboardMappingForNextSteamLaunch))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        standardKeyboardMappingIsSupported
                            ? palette.secondaryText
                            : palette.warning
                    )
            }

            Text(
                appState.localized(
                    "Steam 프리픽스 내부 키보드 입력은 System Default로 유지됩니다. 호스트 보조키 매핑과 macOS 단축키 보호는 설정 > 입력 및 게임 보호에서 관리합니다."
                )
            )
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            if !standardKeyboardMappingIsSupported {
                Text(
                    appState.localized(
                        "지원되지 않는 이전 키보드 저장 값이 있습니다. System Default로 복원한 뒤 설정을 저장하세요."
                    )
                )
                .font(.caption)
                .foregroundStyle(palette.warning)
                .fixedSize(horizontal: false, vertical: true)

                ThemedActionButton(
                    title: "System Default로 복원",
                    systemImage: "arrow.counterclockwise",
                    prominence: .secondary,
                    isDisabled: standardLaunchDraftControlsAreDisabled,
                    controlSize: .small
                ) {
                    keyboardMappingForNextSteamLaunch = .systemDefault
                }
                .frame(minWidth: 170, idealWidth: 210, maxWidth: 260)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.control)
        .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius))
        .accessibilityHint(
            appState.localized(
                "프리픽스 키보드 입력은 읽기 전용이며 System Default로 유지됩니다. 호스트 입력 보호는 설정에서 관리합니다."
            )
        )
    }

    private func experimentalGameModeControl(
        palette: ForgePlayPalette
    ) -> some View {
        Toggle(isOn: $isExperimentalGameModeEnabledForNextLaunch) {
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.localized("Game Mode"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text(appState.localized(
                    "게임 프로세스를 Game Mode 호스트로 실행합니다. 새 구성의 기본값은 켬이며, 저장한 값은 다음 실행에도 다시 사용합니다. 실패하면 게임 실행도 중단됩니다."
                ))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(palette.primary)
        .disabled(standardLaunchDraftControlsAreDisabled)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.control)
        .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius))
        .help(appState.localized(
            "새 구성의 기본값은 켬입니다. 저장한 값은 다음 Steam 실행에도 다시 사용합니다. 켜면 Steam이 시작한 게임 프로세스를 동일 프로세스 Game Mode 호스트로 실행하며, 호스트 적용에 실패하면 해당 게임 실행도 중단됩니다."
        ))
        .accessibilityHint(appState.localized(
            "새 구성의 기본값은 켬입니다. 저장한 값은 다음 Steam 실행에도 다시 사용합니다. 켜면 Steam이 시작한 게임 프로세스를 동일 프로세스 Game Mode 호스트로 실행하며, 호스트 적용에 실패하면 해당 게임 실행도 중단됩니다."
        ))
    }

    private func gameModeStateLabel(isEnabled: Bool) -> String {
        appState.localized(isEnabled ? "켬" : "끔")
    }

    private var standardLaunchDraftControlsAreDisabled: Bool {
        standardLaunchConfigurationRestoreState != .completed ||
            standardLaunchConfigurationRestoreIsBlocked ||
            standardLaunchConfigurationReloadIsAvailable ||
            appState.isSteamLaunchInProgress ||
            services.steamPrefixLifecycleCoordinator.isBusy
    }

    private var standardLaunchConfigurationSaveIsDisabled: Bool {
        selectedRendererForNextSteamLaunch == nil ||
            selectedRendererRuntimeIsUnavailableOrPending ||
            selectedNetworkForNextSteamLaunch == nil ||
            selectedAudioInputForNextSteamLaunch == nil ||
            !standardKeyboardMappingIsSupported ||
            standardLaunchConfigurationRestoreState != .completed ||
            standardLaunchConfigurationRestoreIsBlocked ||
            standardLaunchConfigurationReloadIsAvailable ||
            appState.isSteamLaunchInProgress ||
            appState.steamStorageOperationMountID != nil ||
            services.steamPrefixLifecycleCoordinator.isBusy
    }

    private func restoreStandardLaunchConfigurationOnce() {
        guard standardLaunchConfigurationRestoreState == .pending else { return }
        standardLaunchConfigurationRestoreState = .restoring

        let repository = SteamLaunchConfigurationRepository(container: modelContext.container)
        let recoveryVersion: SteamLaunchConfigurationRecordVersion?
        do {
            recoveryVersion = try repository.standardRecordVersionForRecovery()
        } catch {
            blockStandardLaunchConfigurationRestore(
                appState.localizedFormat(
                    "저장된 표준 Steam 실행 구성을 안전하게 복원하지 못했습니다: %@",
                    appState.localizedError(error)
                ),
                recoveryVersion: nil
            )
            return
        }

        do {
            if let stored = try repository.loadStandard() {
                let selection = try SteamLaunchConfigurationProductAdapter.productSelection(
                    from: stored.snapshot
                )
                applyRestoredStandardLaunchConfiguration(
                    snapshot: stored.snapshot,
                    selection: selection,
                    savedVersion: stored.version
                )
            } else {
                let snapshot = SteamLaunchConfigurationSnapshot.standardDefault
                let selection = try SteamLaunchConfigurationProductAdapter.productSelection(
                    from: snapshot
                )
                applyRestoredStandardLaunchConfiguration(
                    snapshot: snapshot,
                    selection: selection,
                    savedVersion: nil
                )
            }
        } catch {
            blockStandardLaunchConfigurationRestore(
                appState.localizedFormat(
                    "저장된 표준 Steam 실행 구성을 안전하게 복원하지 못했습니다: %@",
                    appState.localizedError(error)
                ),
                recoveryVersion: recoveryVersion
            )
        }
    }

    private func applyRestoredStandardLaunchConfiguration(
        snapshot: SteamLaunchConfigurationSnapshot,
        selection: SteamLaunchConfigurationProductSelection,
        savedVersion: SteamLaunchConfigurationRecordVersion?
    ) {
        selectedRendererForNextSteamLaunch = selection.rendererPolicySelection
        selectedNetworkForNextSteamLaunch = selection.networkSelection
        selectedAudioInputForNextSteamLaunch = selection.audioInputSelection
        keyboardMappingForNextSteamLaunch = selection.keyboardMapping
        appState.wineSynchronizationSelection = selection.synchronizationSelection
        appState.steamVideoMemorySelection = selection.videoMemorySelection
        isExperimentalGameModeEnabledForNextLaunch =
            selection.gameModePolicy == .experimentalRequiredHost
        standardLaunchDraftBase = snapshot
        savedStandardLaunchConfigurationDigest = savedVersion?.digest
        savedStandardLaunchConfigurationVersion = savedVersion
        standardLaunchConfigurationSaveFailed = false
        standardLaunchConfigurationRestoreIsBlocked = false
        standardLaunchConfigurationReloadIsAvailable = false
        standardLaunchConfigurationErrorMessage = nil
        standardLaunchConfigurationRestoreState = .completed
    }

    private func blockStandardLaunchConfigurationRestore(
        _ message: String,
        recoveryVersion: SteamLaunchConfigurationRecordVersion?
    ) {
        selectedRendererForNextSteamLaunch = nil
        selectedNetworkForNextSteamLaunch = nil
        selectedAudioInputForNextSteamLaunch = nil
        keyboardMappingForNextSteamLaunch = .systemDefault
        savedStandardLaunchConfigurationDigest = nil
        savedStandardLaunchConfigurationVersion = recoveryVersion
        standardLaunchConfigurationSaveFailed = false
        standardLaunchConfigurationRestoreIsBlocked = true
        standardLaunchConfigurationReloadIsAvailable = false
        standardLaunchConfigurationErrorMessage = message
        standardLaunchConfigurationRestoreState = .completed
    }

    private func resetBlockedStandardLaunchConfiguration() {
        guard standardLaunchConfigurationRestoreIsBlocked else { return }
        guard let expectedVersion = savedStandardLaunchConfigurationVersion else { return }
        guard !appState.isSteamLaunchInProgress,
              !services.steamPrefixLifecycleCoordinator.isBusy else {
            standardLaunchConfigurationErrorMessage = appState.localized(
                "다른 Steam 작업이 끝난 뒤 저장된 구성을 초기화하세요."
            )
            return
        }

        do {
            let repository = SteamLaunchConfigurationRepository(container: modelContext.container)
            try repository.resetStandard(expectedVersion: expectedVersion)
            reloadLatestStandardLaunchConfiguration()
        } catch {
            standardLaunchConfigurationRestoreIsBlocked = true
            presentStandardLaunchConfigurationPersistenceError(
                error,
                fallbackFormatKey: "저장된 표준 Steam 실행 구성을 초기화하지 못했습니다: %@"
            )
        }
    }

    private func reloadLatestStandardLaunchConfiguration() {
        guard !appState.isSteamLaunchInProgress,
              !services.steamPrefixLifecycleCoordinator.isBusy else {
            return
        }

        let repository = SteamLaunchConfigurationRepository(container: modelContext.container)
        let recoveryVersion: SteamLaunchConfigurationRecordVersion?
        do {
            recoveryVersion = try repository.standardRecordVersionForRecovery()
        } catch {
            blockStandardLaunchConfigurationRestore(
                appState.localizedFormat(
                    "최신 Steam 실행 구성을 다시 불러오지 못했습니다: %@",
                    appState.localizedError(error)
                ),
                recoveryVersion: nil
            )
            return
        }

        do {
            if let stored = try repository.loadStandard() {
                let selection = try SteamLaunchConfigurationProductAdapter.productSelection(
                    from: stored.snapshot
                )
                applyRestoredStandardLaunchConfiguration(
                    snapshot: stored.snapshot,
                    selection: selection,
                    savedVersion: stored.version
                )
                let notice = appState.setNotice(
                    appState.localized("최신 Steam 실행 구성을 다시 불러왔습니다."),
                    kind: .success
                )
                clearTaskLater(notice.id)
            } else {
                let snapshot = SteamLaunchConfigurationSnapshot.standardDefault
                let selection = try SteamLaunchConfigurationProductAdapter.productSelection(
                    from: snapshot
                )
                applyRestoredStandardLaunchConfiguration(
                    snapshot: snapshot,
                    selection: selection,
                    savedVersion: nil
                )
                let notice = appState.setNotice(
                    appState.localized(
                        "저장된 Steam 실행 구성이 없어 안전한 기본값을 저장되지 않은 초안으로 불러왔습니다."
                    ),
                    kind: .success
                )
                clearTaskLater(notice.id)
            }
        } catch {
            blockStandardLaunchConfigurationRestore(
                appState.localizedFormat(
                    "최신 Steam 실행 구성을 다시 불러오지 못했습니다: %@",
                    appState.localizedError(error)
                ),
                recoveryVersion: recoveryVersion
            )
        }
    }

    private func currentStandardLaunchProductSelection() throws
        -> SteamLaunchConfigurationProductSelection
    {
        guard let rendererPolicySelection = selectedRendererForNextSteamLaunch else {
            throw SteamLaunchConfigurationProductAdapterError.unsupportedOption(
                category: "draft",
                value: "renderer-not-selected"
            )
        }
        guard let networkSelection = selectedNetworkForNextSteamLaunch else {
            throw SteamLaunchConfigurationProductAdapterError.unsupportedOption(
                category: "draft",
                value: "network-not-selected"
            )
        }
        guard let audioInputSelection = selectedAudioInputForNextSteamLaunch else {
            throw SteamLaunchConfigurationProductAdapterError.unsupportedOption(
                category: "draft",
                value: "audio-input-not-selected"
            )
        }
        guard standardKeyboardMappingIsSupported else {
            throw SteamLaunchConfigurationProductAdapterError.unsupportedOption(
                category: "keyboard-mapping",
                value: "system-default-required"
            )
        }
        return SteamLaunchConfigurationProductSelection(
            rendererPolicySelection: rendererPolicySelection,
            networkSelection: networkSelection,
            audioInputSelection: audioInputSelection,
            synchronizationSelection: appState.wineSynchronizationSelection,
            videoMemorySelection: appState.steamVideoMemorySelection,
            gameModePolicy: isExperimentalGameModeEnabledForNextLaunch
                ? .experimentalRequiredHost
                : .standard,
            fpsCursorPolicy: standardLaunchDraftBase.fpsCursorPolicy,
            controllerPolicy: standardLaunchDraftBase.controllerPolicy,
            keyboardMapping: keyboardMappingForNextSteamLaunch
        )
    }

    private func currentStandardLaunchConfigurationSnapshot() throws
        -> SteamLaunchConfigurationSnapshot
    {
        try SteamLaunchConfigurationProductAdapter.standardSnapshot(
            selection: currentStandardLaunchProductSelection(),
            preserving: standardLaunchDraftBase
        )
    }

    private func persistCurrentStandardLaunchConfiguration() throws
        -> SavedStandardSteamLaunchConfiguration
    {
        let snapshot = try currentStandardLaunchConfigurationSnapshot()
        let selection = try SteamLaunchConfigurationProductAdapter.productSelection(
            from: snapshot
        )
        let repository = SteamLaunchConfigurationRepository(container: modelContext.container)
        let stored = try repository.saveStandard(
            snapshot,
            expectedVersion: savedStandardLaunchConfigurationVersion
        )
        standardLaunchDraftBase = stored.snapshot
        savedStandardLaunchConfigurationDigest = stored.version.digest
        savedStandardLaunchConfigurationVersion = stored.version
        standardLaunchConfigurationSaveFailed = false
        standardLaunchConfigurationReloadIsAvailable = false
        standardLaunchConfigurationErrorMessage = nil
        return SavedStandardSteamLaunchConfiguration(
            snapshot: stored.snapshot,
            selection: selection
        )
    }

    private func saveStandardLaunchConfigurationFromAction() {
        guard standardLaunchConfigurationRestoreState == .completed else {
            appState.setNotice(
                appState.localized(
                    "저장된 Steam 실행 구성을 읽은 뒤 그래픽 백엔드, 네트워크, 오디오 입력을 모두 확인해야 Steam을 실행할 수 있습니다."
                ),
                kind: .warning
            )
            return
        }
        guard standardKeyboardMappingIsSupported else {
            appState.setNotice(
                appState.localized(
                    "지원되지 않는 이전 키보드 저장 값이 있습니다. System Default로 복원한 뒤 설정을 저장하세요."
                ),
                kind: .warning
            )
            return
        }
        if selectedRendererRuntimeIsUnavailableOrPending {
            let messageKey = cachedRendererAvailability(for: .vulkan)?
                .userMessageLocalizationKey ??
                SteamRendererPolicyPreference.dxvkRuntimeUnavailableLocalizationKey
            appState.setNotice(appState.localized(messageKey), kind: .warning)
            return
        }
        do {
            _ = try persistCurrentStandardLaunchConfiguration()
            let notice = appState.setNotice(
                appState.localized("Steam 실행 구성을 저장했습니다."),
                kind: .success
            )
            clearTaskLater(notice.id)
        } catch {
            presentStandardLaunchConfigurationPersistenceError(
                error,
                fallbackFormatKey: "Steam 실행 구성을 저장하지 못했습니다: %@"
            )
        }
    }

    private func presentStandardLaunchConfigurationPersistenceError(
        _ error: Error,
        fallbackFormatKey: String
    ) {
        standardLaunchConfigurationSaveFailed = true
        if let persistenceError = error as? SteamLaunchConfigurationPersistenceError,
           case .writeConflict = persistenceError {
            standardLaunchConfigurationReloadIsAvailable = true
            standardLaunchConfigurationErrorMessage = appState.localized(
                "다른 창에서 Steam 실행 구성이 변경되었습니다. 현재 초안과 화면 상태는 유지했습니다. 최신 구성을 다시 불러온 뒤 다시 시도하세요."
            )
            return
        }

        standardLaunchConfigurationErrorMessage = appState.localizedFormat(
            fallbackFormatKey,
            appState.localizedError(error)
        )
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
                Text(appState.localized("macOS 저장공간을 연결해 ForgePlay에 접근 권한을 부여하세요. 빈 위치는 Steam이 새 라이브러리를 만들 수 있는 Windows 드라이브로 연결하고, 기존 SteamLibrary는 자동 인식합니다."))
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
                        detail: "빈 외장 드라이브/폴더는 Steam이 새 라이브러리를 만들 수 있는 Windows 드라이브로 연결하고, 기존 SteamLibrary는 자동 인식합니다. 파일은 복사하지 않습니다.",
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
        let storageDrivePath = SteamManager.mappedWindowsLibraryPath(
            for: mount.url,
            prefix: prefix
        )
        let libraryPaths = services.steamManager
            .normalizedLibraryRoots(for: mount.url)
            .compactMap {
                SteamManager.mappedWindowsLibraryPath(for: $0, prefix: prefix)
            }
        var seen = Set<String>()
        let mappedPaths = ([storageDrivePath].compactMap { $0 } + libraryPaths)
            .filter { seen.insert($0.lowercased()).inserted }
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
                Text(appState.localized("게임별 호환성 안내를 사용하려면 진단 대상을 선택하세요. 선택은 게임을 직접 실행하거나 Steam 실행 설정을 자동으로 바꾸지 않습니다."))
                    .font(.caption)
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
                steamReferenceRecordActions(game)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    steamReferenceRecordIcon(palette: palette)
                    steamReferenceRecordDetails(game, palette: palette)
                        .layoutPriority(1)
                }
                steamReferenceRecordActions(game)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        }
        .padding(12)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isSelectedSteamReference(game)
                        ? palette.primary.opacity(0.72)
                        : palette.border,
                    lineWidth: 1
                )
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
            if isSelectedSteamReference(game) {
                Label(
                    appState.localized("진단 대상으로 선택됨"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func steamReferenceRecordActions(
        _ game: SteamGameRecord
    ) -> some View {
        ResponsiveActionRow(spacing: 8) {
            ThemedActionButton(
                title: isSelectedSteamReference(game)
                    ? "진단 대상 해제"
                    : "진단 대상으로 선택",
                systemImage: isSelectedSteamReference(game)
                    ? "checkmark.circle.fill"
                    : "scope",
                prominence: isSelectedSteamReference(game)
                    ? .primary
                    : .secondary,
                controlSize: .small
            ) {
                toggleSteamReferenceSelection(game)
            }
            .frame(minWidth: 130, idealWidth: 150, maxWidth: 180)
            steamReferenceRemoveButton(game)
        }
    }

    private func isSelectedSteamReference(_ game: SteamGameRecord) -> Bool {
        appState.selectedSteamReference?.steamAppId == game.steamAppId
    }

    private func toggleSteamReferenceSelection(_ game: SteamGameRecord) {
        if isSelectedSteamReference(game) {
            appState.selectedSteamReference = nil
            appState.setNotice(
                appState.localized("게임별 진단 대상 선택을 해제했습니다."),
                kind: .success
            )
        } else {
            appState.selectedSteamReference = game.game
            appState.setNotice(
                appState.localizedFormat(
                    "%@을 게임별 진단 대상으로 선택했습니다. Steam은 기존처럼 별도로 실행됩니다.",
                    game.name
                ),
                kind: .success
            )
        }
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
        guard steamLaunchReadinessSnapshotIsCurrent else {
            return appState.localized("Steam 상태 확인 필요")
        }
        if cachedSteamLaunchBlocker != nil { return appState.localized("Steam 실행 차단") }
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
        guard steamLaunchReadinessSnapshotIsCurrent else { return .warning }
        if cachedSteamLaunchBlocker != nil { return .warning }
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
        guard steamLaunchReadinessSnapshotIsCurrent else {
            return appState.localized("Steam 상태 확인 필요")
        }
        if let blocker = cachedSteamLaunchBlocker {
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
        _ = launchRecords.first?.id
        return try? services.steamLaunchReadinessRepository.latestDisplayRecord(
            in: modelContext,
            environmentIdentity: SteamEnvironmentIdentity(
                generationID: readiness.steamEnvironmentGenerationID,
                createdAt: readiness.steamEnvironmentCreatedAt
            ),
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

    @MainActor
    private func refreshSteamLaunchReadiness(taskID: String) async {
        let readiness = readiness
        let runtimeExecutable = appState.runtimeExecutableURL
        let selection = selectedRendererForNextSteamLaunch

        if let blocker = cachedSteamLaunchBlockerBeforeRuntimeInspection(
            readiness: readiness,
            runtimeExecutable: runtimeExecutable
        ) {
            guard !Task.isCancelled, taskID == steamLaunchReadinessTaskID else { return }
            steamLaunchReadinessSnapshot = SteamLaunchReadinessSnapshot(
                taskID: taskID,
                steamLaunchBlocker: blocker,
                selectedRendererLaunchBlocker: nil,
                rendererAvailabilityBySelection: [:]
            )
            return
        }

        guard let runtimeExecutable else { return }
        let selectionRawValue = selection?.rawValue
        let runtimeSnapshot: WindowsRuntimeCapabilitySnapshot
        do {
            runtimeSnapshot = try await services.windowsRuntimeService
                .runtimeCapabilitySnapshot(executable: runtimeExecutable)
        } catch {
            guard !Task.isCancelled,
                  taskID == steamLaunchReadinessTaskID else {
                return
            }
            steamLaunchReadinessSnapshot = SteamLaunchReadinessSnapshot(
                taskID: taskID,
                steamLaunchBlocker: forgePlayTechnicalErrorSummary(error),
                selectedRendererLaunchBlocker: nil,
                rendererAvailabilityBySelection: [:]
            )
            return
        }
        guard let inspection = await steamLaunchReadinessInspectionCoordinator.inspect(
            capability: runtimeSnapshot.capability,
            selectionRawValue: selectionRawValue
        ) else {
            return
        }

        guard !Task.isCancelled, taskID == steamLaunchReadinessTaskID else { return }
        let steamBlocker = cachedSteamLaunchBlocker(
            readiness: readiness,
            inspection: inspection
        )
        let rendererBlocker: String?
        if let selection,
           let availability = inspection
            .rendererAvailabilityBySelection[selection],
           !availability.isAvailable {
            if let messageKey = availability.userMessageLocalizationKey {
                rendererBlocker = appState.localized(messageKey)
            } else {
                rendererBlocker = appState.localizedFormat(
                    "%@ 단일 백엔드 파일이 완전하지 않아 이번 Steam 실행을 시작할 수 없습니다. 다른 백엔드를 선택하거나 ForgePlay Runtime을 다시 설치하세요.",
                    appState.localized(selection.labelKey)
                )
            }
        } else {
            rendererBlocker = nil
        }
        steamLaunchReadinessSnapshot = SteamLaunchReadinessSnapshot(
            taskID: taskID,
            steamLaunchBlocker: steamBlocker,
            selectedRendererLaunchBlocker: rendererBlocker,
            rendererAvailabilityBySelection:
                inspection.rendererAvailabilityBySelection
        )
    }

    private func cachedSteamLaunchBlockerBeforeRuntimeInspection(
        readiness: SetupReadiness,
        runtimeExecutable: URL?
    ) -> String? {
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
        guard runtimeExecutable != nil else {
            return appState.localized("ForgePlay Runtime을 먼저 확인하세요.")
        }
        return nil
    }

    private func cachedSteamLaunchBlocker(
        readiness: SetupReadiness,
        inspection: SteamLaunchRuntimeInspection
    ) -> String? {
        guard inspection.canLaunchWindowsSteam else {
            return appState.localized(inspection.steamLaunchMessageKey)
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
            message: appState.localized("외장 드라이브의 최상위 폴더, 빈 폴더 또는 기존 SteamLibrary 폴더를 선택하세요. 다음 Steam 실행 때 Windows 드라이브로 연결됩니다."),
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
                        appState.localized("Steam 저장공간을 연결했습니다. 다음 Steam 실행에서 새 라이브러리를 만들거나 기존 라이브러리를 자동으로 인식할 수 있습니다."),
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

        let steamLanguage = appState.effectiveSteamClientLanguage
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
                let installResult = try await services.installSteamInSteamPrefix(
                    runtimeExecutable: runtimeExecutable,
                    installer: installer,
                    language: steamLanguage,
                    videoMemorySelection: appState.steamVideoMemorySelection,
                    synchronizationSelection: appState.wineSynchronizationSelection
                )
                let result = installResult.processResult
                try await refreshSetupWorkflowUntilCommitted()

                switch installResult.verificationState {
                case .verified, .steamClientServiceNotReady:
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
                        kind: installResult.verificationState == .verified &&
                            steamInstallerPersistenceWarningForRebuild == nil &&
                            prefixPersistenceWarning == nil &&
                            rollbackCleanupWarning == nil &&
                            installResult.compatibilityPreparationWarning == nil ? .success : .warning,
                        logURL: result.stdoutLog
                    )
                    clearTaskLater(notice.id)
                case .steamLanguageNotReady:
                    appState.setNotice(
                        DiagnosticWarningText.combined(
                            appState.localized("Steam 자체 언어 설정을 첫 화면 전에 검증하지 못해 설치 완료로 처리하지 않았습니다."),
                            steamInstallerPersistenceWarningForRebuild,
                            prefixPersistenceWarning,
                            rollbackCleanupWarning,
                            installResult.compatibilityPreparationWarning.map {
                                appState.localizedFormat("Steam 실행 경로 자동 준비는 완료하지 못했습니다. 첫 Steam 실행에서 다시 시도합니다: %@", $0)
                            }
                        ) ?? appState.localized("Steam 자체 언어 설정을 첫 화면 전에 검증하지 못해 설치 완료로 처리하지 않았습니다."),
                        kind: .failure,
                        logURL: result.stderrLog,
                        diagnosticProcessResult: result
                    )
                case .installerFailed, .steamExecutableNotCreatedOrChanged:
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

    private func refreshSetupWorkflowUntilCommitted() async throws {
        while true {
            do {
                _ = try await services.refreshSetupWorkflow(
                    appState: appState,
                    in: modelContext,
                    hasSteamReferences: !games.isEmpty
                )
                return
            } catch SetupWorkflowRefreshControlError.superseded {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    private func launchSteam() {
        guard standardLaunchConfigurationRestoreState == .completed else {
            appState.setNotice(
                appState.localized(
                    "저장된 Steam 실행 구성을 읽은 뒤 그래픽 백엔드, 네트워크, 오디오 입력을 모두 확인해야 Steam을 실행할 수 있습니다."
                ),
                kind: .warning
            )
            return
        }
        guard !standardLaunchConfigurationReloadIsAvailable else { return }
        if let blockerKey = gameInputProtectionAuthorizationBlockerKey {
            appState.setNotice(appState.localized(blockerKey), kind: .warning)
            return
        }
        guard standardLaunchDraftIsSaved else {
            appState.setNotice(
                appState.localized(
                    "변경한 Steam 실행 구성은 저장에 성공한 뒤에만 실행할 수 있습니다."
                ),
                kind: .warning
            )
            return
        }
        guard selectedRendererForNextSteamLaunch != nil else {
            appState.setNotice(
                appState.localized("이번 Steam 실행에 사용할 그래픽 백엔드를 직접 선택하세요."),
                kind: .warning
            )
            return
        }
        guard selectedNetworkForNextSteamLaunch != nil else {
            appState.setNotice(
                appState.localized("이번 Steam 실행에 사용할 네트워크 호환성 방식을 직접 선택하세요."),
                kind: .warning
            )
            return
        }
        guard selectedAudioInputForNextSteamLaunch != nil else {
            appState.setNotice(
                appState.localized("이번 Steam 실행에서 오디오 입력을 끌지 켤지 직접 선택하세요."),
                kind: .warning
            )
            return
        }
        guard standardKeyboardMappingIsSupported else {
            appState.setNotice(
                appState.localized(
                    "지원되지 않는 이전 키보드 저장 값이 있습니다. System Default로 복원한 뒤 설정을 저장하세요."
                ),
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
        if let blockerKey = StandardSteamLaunchReservationFailurePolicy
            .preflightBlockerLocalizationKey(
                isWindowsExecutableLaunchReserved: services
                    .steamCompatibilitySessionCoordinator
                    .isWindowsExecutableLaunchReserved
            ) {
            appState.setNotice(appState.localized(blockerKey), kind: .warning)
            return
        }
        switch standardSteamCompatibilitySessionHandoff {
        case .blockedByCompatibilityTransition:
            appState.setNotice(
                appState.localized("호환성 Steam 세션 작업이 이미 진행 중입니다."),
                kind: .warning
            )
            return
        case .blockedByAnotherPrefixOperation:
            appState.setNotice(
                appState.localized("다른 Steam 프리픽스 작업이 이미 진행 중입니다. 완료된 뒤 다시 시도하세요."),
                kind: .warning
            )
            return
        case .ready, .reconcileActiveSession:
            break
        }
        guard steamLaunchReadinessSnapshotIsCurrent else {
            appState.setNotice(
                appState.localized(
                    "ForgePlay Runtime과 Steam 실행 준비 상태를 확인하는 중입니다. 잠시 후 다시 시도하세요."
                ),
                kind: .warning
            )
            return
        }
        if let blocker = cachedSteamLaunchBlocker {
            appState.setNotice(blocker, kind: .warning)
            return
        }
        if let blocker = cachedSelectedRendererLaunchBlocker {
            appState.setNotice(blocker, kind: .warning)
            return
        }
        guard let runtimeExecutable = appState.runtimeExecutableURL else {
            appState.setNotice(appState.localized("ForgePlay Runtime을 먼저 확인하세요."), kind: .warning)
            return
        }

        let savedConfiguration: SavedStandardSteamLaunchConfiguration
        let resolvedJournal: SteamLaunchConfigurationTransactionJournal
        do {
            let snapshot = try currentStandardLaunchConfigurationSnapshot()
            let selection = try currentStandardLaunchProductSelection()
            guard let savedDigest = savedStandardLaunchConfigurationDigest,
                  snapshot == standardLaunchDraftBase,
                  try snapshot.canonicalDigest == savedDigest else {
                throw SteamLaunchConfigurationPersistenceError.digestMismatch
            }
            savedConfiguration = SavedStandardSteamLaunchConfiguration(
                snapshot: snapshot,
                selection: selection
            )
            resolvedJournal = try SteamLaunchConfigurationProductAdapter.resolvedJournal(
                for: savedConfiguration.snapshot,
                transactionID: UUID()
            )
        } catch {
            presentStandardLaunchConfigurationPersistenceError(
                error,
                fallbackFormatKey: "Steam 실행 구성을 저장하지 못해 실행을 시작하지 않았습니다: %@"
            )
            return
        }

        let productSelection = savedConfiguration.selection
        let rendererPolicySelection = productSelection.rendererPolicySelection
        let networkSelection = productSelection.networkSelection
        let audioInputSelection = productSelection.audioInputSelection
        let gameModePolicy = productSelection.gameModePolicy
        let launchingConfiguration = ActiveSteamSessionConfiguration(
            rendererSelection: rendererPolicySelection,
            networkSelection: networkSelection,
            audioInputSelection: audioInputSelection,
            synchronizationSelection: productSelection.synchronizationSelection,
            videoMemorySelection: productSelection.videoMemorySelection,
            gameModePolicy: gameModePolicy,
            fpsCursorPolicy: productSelection.fpsCursorPolicy,
            controllerPolicy: productSelection.controllerPolicy,
            keyboardMapping: productSelection.keyboardMapping
        )
        let compatibilitySessionCoordinator =
            services.steamCompatibilitySessionCoordinator
        let standardLaunchReservation: StandardSteamLaunchReservation
        do {
            standardLaunchReservation = try compatibilitySessionCoordinator
                .reserveStandardSteamLaunch(
                    prefixLifecycleIsBusy:
                        services.steamPrefixLifecycleCoordinator.isBusy
                )
        } catch let ownershipError as NavigationStableSessionOwnershipError {
            let messageKey = StandardSteamLaunchReservationFailurePolicy
                .localizationKey(for: ownershipError)
            appState.setNotice(appState.localized(messageKey), kind: .warning)
            return
        } catch {
            appState.setError(error)
            return
        }
        steamSessionConfigurationBeingLaunched = launchingConfiguration
        appState.isSteamLaunchInProgress = true
        appState.setTask(appState.localized("Windows용 Steam을 실행하는 중입니다."))
        let selectedGame = appState.selectedSteamReference
        let selectedGameContext = selectedGame.map {
            DiagnosticEnvironmentSnapshotCollector.captureLaunchSelectedGameContext($0)
        }
        let steamClientLanguage = appState.effectiveSteamClientLanguage
        Task {
            defer {
                compatibilitySessionCoordinator.releaseStandardSteamLaunchReservation(
                    standardLaunchReservation
                )
                steamSessionConfigurationBeingLaunched = nil
                appState.isSteamLaunchInProgress = false
            }
            var launchRecord: LaunchRecord?
            do {
                if standardLaunchReservation.requiresCompatibilityReconciliation {
                    appState.setTask(
                        appState.localized(
                            "관리 Wine 프로세스 종료와 기준 상태 복원을 확인하는 중입니다."
                        )
                    )
                    try await compatibilitySessionCoordinator
                        .reconcileCompatibilitySessionForStandardSteamLaunch(
                            standardLaunchReservation
                        )
                }
                let libraryAccess = try appState.restorePersistedSteamStorageAccess(
                    in: modelContext
                )
                try compatibilitySessionCoordinator.validateStandardSteamLaunchReservation(
                    standardLaunchReservation,
                    prefixLifecycleIsBusy:
                        services.steamPrefixLifecycleCoordinator.isBusy
                )
                let launch = try await services.steamPrefixService.launchSteam(
                    runtimeExecutable: runtimeExecutable,
                    steamClientLanguage: steamClientLanguage,
                    rendererPolicySelection: rendererPolicySelection,
                    networkSelection: networkSelection,
                    audioInputSelection: audioInputSelection,
                    fpsCursorPolicy: productSelection.fpsCursorPolicy,
                    controllerPolicy: productSelection.controllerPolicy,
                    keyboardMapping: productSelection.keyboardMapping,
                    gameModePolicy: gameModePolicy,
                    videoMemorySelection: productSelection.videoMemorySelection,
                    synchronizationSelection: productSelection.synchronizationSelection,
                    libraryRoots: libraryAccess.roots,
                    reservedLibraryRoots: libraryAccess.driveReservationRoots,
                    prepareLaunch: {
                        let environmentGenerationID = try services.currentSteamEnvironmentGenerationID()
                        let record = try modelContext.createSteamLaunchRecord(
                            appSessionID: services.appSessionID,
                            environmentGenerationID: environmentGenerationID,
                            selectedGameContext: selectedGameContext,
                            resolvedSnapshot: savedConfiguration.snapshot,
                            resolvedJournal: resolvedJournal
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
                let detachedInputProtectionWarning =
                    result.inputProtectionDegradedForDetachedHandoff
                    ? appState.localized(
                        "이번 Steam 세션에서는 포인터 숨김 보호를 적용하지 못했습니다. Steam과 게임 실행은 계속되며, 권한이 필요한 키 보호 설정에는 이 예외를 적용하지 않습니다."
                    )
                    : nil
                let gameModeSessionInformation =
                    gameModePolicy == .experimentalRequiredHost
                    ? appState.localized(
                        "현재 Steam 세션은 Game Mode 켬으로 시작했습니다. Steam에서 실행하는 게임 프로세스에 호스트를 적용하며, 전체 화면 실행 중 macOS 메뉴 막대에서 활성 상태를 확인할 수 있습니다."
                    )
                    : nil
                let providerReceiptsApplied =
                    (result.inputCompatibilityReceipt?
                        .isLifecycleAdmissionVerified == true ||
                        result.inputProtectionDegradedForDetachedHandoff) &&
                    result.controllerCompatibilityReceipt?.isStaticPreparationVerified == true &&
                    result.windowsFontProvisioningReceipt?.isAppliedAndReadBack == true &&
                    result.rendererRouteApplicationReceipt?.isPreparationVerified == true
                if result.succeeded && providerReceiptsApplied {
                    let message = result.steamUIStartupRecoveryAttemptCount > 0
                        ? appState.localized("Steam UI 초기화 실패를 자동으로 복구하고 Windows용 Steam을 다시 시작했습니다. 로그인 또는 라이브러리 화면을 확인하세요.")
                        : appState.localized("Windows용 Steam 프로세스를 시작했습니다. Steam 창에서 로그인 또는 라이브러리 화면이 보이는지 확인하세요.")
                    let hasLaunchWarning = libraryAccess.unavailableCount > 0 ||
                        processUserFacingWarning != nil ||
                        detachedInputProtectionWarning != nil ||
                        launchPersistenceWarning != nil
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
                            detachedInputProtectionWarning,
                            gameModeSessionInformation,
                            launchPersistenceWarning
                        ) ?? message,
                        kind: hasLaunchWarning ? .warning : .success,
                        logURL: result.preferredDiagnosticLog
                    )
                    if !hasLaunchWarning {
                        clearTaskLater(notice.id)
                    }
                } else if result.forgePlayStatusCode == SteamManager.steamBootstrapUpdateInProgressExitCode {
                    let message = appState.localized("Windows용 Steam 업데이트가 진행 중입니다. ForgePlay가 Steam을 종료하지 않았습니다. 업데이트가 끝나면 같은 화면에서 Steam UI 렌더링을 확인하세요.")
                    let notice = appState.setNotice(
                        DiagnosticWarningText.combined(
                            message,
                            processUserFacingWarning,
                            detachedInputProtectionWarning,
                            gameModeSessionInformation,
                            launchPersistenceWarning
                        ) ?? message,
                        kind: .warning,
                        logURL: result.preferredDiagnosticLog
                    )
                    if processUserFacingWarning == nil &&
                        launchPersistenceWarning == nil {
                        clearTaskLater(notice.id)
                    }
                } else if result.forgePlayStatusCode == SteamManager.steamLaunchProcessVerificationUnavailableExitCode {
                    let message = appState.localized("Windows용 Steam 실행 명령은 전달됐지만 실제 프로세스 실행 증거를 확인하지 못했습니다. Steam 창을 직접 확인해야 하며, 검은 화면이면 성공으로 보지 않습니다.")
                    let notice = appState.setNotice(
                        DiagnosticWarningText.combined(
                            message,
                            processUserFacingWarning,
                            detachedInputProtectionWarning,
                            gameModeSessionInformation,
                            launchPersistenceWarning
                        ) ?? message,
                        kind: .warning,
                        logURL: result.preferredDiagnosticLog
                    )
                    if processUserFacingWarning == nil &&
                        launchPersistenceWarning == nil {
                        clearTaskLater(notice.id)
                    }
                } else {
                    presentSteamGuidance(
                        for: result,
                        launchPersistenceWarning: launchPersistenceWarning,
                        launchRecordId: record.id,
                        gameId: record.gameId,
                        game: selectedGame
                    )
                    appState.setNotice(
                        appState.localizedFormat("Steam 실행에 실패했습니다. 로그를 확인하세요: %@", result.preferredDiagnosticLog.path),
                        kind: .failure,
                        logURL: result.preferredDiagnosticLog,
                        diagnosticProcessResult: result
                    )
                }
            } catch {
                if let result = processRunResult(from: error) {
                    presentSteamGuidance(
                        for: result,
                        launchRecordId: launchRecord?.id,
                        gameId: launchRecord?.gameId ?? selectedGameContext?.steamAppID,
                        game: selectedGame
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
    }

    private func markSteamUIBlackScreen(_ launchRecord: LaunchRecord) {
        if let notice = steamLaunchRecordLifecycle.markSteamUIBlackScreen(launchRecord) {
            clearTaskLater(notice.id)
        }
    }

    private func presentSteamGuidance(
        for result: ProcessRunResult,
        prefixPersistenceWarning: String? = nil,
        launchPersistenceWarning: String? = nil,
        launchRecordId: String? = nil,
        gameId: String? = nil,
        game: SteamGame? = nil
    ) {
        let logSnapshot = LogTextReader.tolerantDiagnosticSnapshot(from: result.diagnosticSourceLogs)
        let compatibilityGuidance = diagnosticCompatibilityGuidance(for: game)
        let diagnostics = DiagnosticGuidanceBuilder.diagnostics(
            ruleEngine: services.ruleEngine,
            logText: logSnapshot.text,
            game: game,
            recipe: compatibilityGuidance.recipe,
            context: .setupOrInstaller,
            language: appState.effectiveLanguageMode,
            fallbackReason: appState.localized("Steam 실행 단계에서 실패했습니다. 로그를 열어 마지막 오류를 확인하고, Steam 프리픽스와 ForgePlay Runtime 상태를 다시 점검하세요.")
        )
        let diagnosticPersistenceWarning = saveDiagnosticRecords(
            diagnostics,
            launchRecordId: launchRecordId,
            gameId: gameId ?? game?.steamAppId
        )
        appState.presentDiagnosticGuide(
            title: "Steam",
            diagnostics: diagnostics,
            logURL: result.preferredDiagnosticLog,
            persistenceWarning: DiagnosticWarningText.combined(
                logSnapshot.readError.map { appState.localizedError($0) },
                prefixPersistenceWarning,
                launchPersistenceWarning,
                compatibilityGuidance.warning,
                diagnosticPersistenceWarning
            )
        )
    }

    private func diagnosticCompatibilityGuidance(
        for game: SteamGame?
    ) -> (recipe: CompatibilityRecipe?, warning: String?) {
        guard let game else { return (nil, nil) }
        do {
            let steamAppID = game.steamAppId
            var descriptor = FetchDescriptor<CompatibilityRecipeRecord>(
                predicate: #Predicate {
                    $0.steamAppId == steamAppID
                },
                sortBy: [SortDescriptor(\.recipeId)]
            )
            // Two rows are enough to prove ambiguity without materializing
            // the complete signed guidance snapshot for every launch failure.
            descriptor.fetchLimit = 2
            let storedRecords = try modelContext.fetch(descriptor)
            return (
                try services.compatibilityService.diagnosticGuidanceRecipe(
                    for: game,
                    storedRecords: storedRecords
                ),
                nil
            )
        } catch {
            return (
                nil,
                appState.localizedFormat(
                    "선택한 게임의 호환성 안내를 읽지 못했습니다: %@",
                    appState.localizedError(error)
                )
            )
        }
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
