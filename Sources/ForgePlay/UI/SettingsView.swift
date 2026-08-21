import AppKit
import SwiftData
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case input
    case environment
    case maintenance
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "일반"
        case .input: "입력 및 게임 보호"
        case .environment: "프리픽스 · 동기화"
        case .maintenance: "진단 및 데이터"
        case .about: "정보"
        }
    }
}

enum AWDLTogglePresentation: Hashable, Sendable {
    case unavailable
    case enabled
    case disabled

    init(interfaceState: AWDLInterfaceState) {
        switch interfaceState {
        case .unavailable: self = .unavailable
        case .enabled: self = .enabled
        case .disabled: self = .disabled
        }
    }

    var isOn: Bool? {
        switch self {
        case .unavailable: nil
        case .enabled: true
        case .disabled: false
        }
    }
}

struct SettingsView: View {
    var sheetPresenter: ((SheetDestination) -> Void)? = nil
    var opensMainWindowForNavigation = false
    var performsInitialWorkflowRefresh = true
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \SteamGameRecord.name) private var games: [SteamGameRecord]
    @Query private var launchRecords: [LaunchRecord]
    @Query(sort: \CompatibilityRecipeRecord.name) private var compatibilityRecipes: [CompatibilityRecipeRecord]
    @State private var statusMessage = ""
    @State private var compatibilityDBURL = ""
    @State private var compatibilityDBStatusMessage = ""
    @State private var logCleanupStatusMessage = ""
    @State private var legalDocumentStatusMessage = ""
    @State private var isShowingSteamPrefixConfirmation = false
    @State private var isShowingLogCleanupConfirmation = false
    @State private var isCreatingSteamPrefix = false
    @State private var isCleaningLogs = false
    @State private var selectedPane: SettingsPane = .general
    private let languageOptionMinimumWidth: CGFloat = 160

    init(
        sheetPresenter: ((SheetDestination) -> Void)? = nil,
        opensMainWindowForNavigation: Bool = false,
        performsInitialWorkflowRefresh: Bool = true
    ) {
        self.sheetPresenter = sheetPresenter
        self.opensMainWindowForNavigation = opensMainWindowForNavigation
        self.performsInitialWorkflowRefresh = performsInitialWorkflowRefresh
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

    private var readiness: SetupReadiness {
        appState.setupReadiness
    }

    private var setupReadinessObservationKey: SetupReadinessObservationKey? {
        _ = launchRecords.first?.id
        return try? services.setupReadinessObservationKey(
            appState: appState,
            in: modelContext,
            hasSteamReferences: !games.isEmpty
        )
    }

    private var runtimeSystemCheck: SystemCheckResult? {
        appState.latestChecks.first { $0.category == .windowsRuntime }
    }

    private func presentSheet(_ destination: SheetDestination) {
        if let sheetPresenter {
            sheetPresenter(destination)
        } else {
            appState.presentedSheet = destination
        }
    }

    private func openMainWindow(section: AppSection) {
        appState.selectedSection = section
        if opensMainWindowForNavigation {
            openWindow(id: ForgePlaySceneID.main)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var currentLanguageDisplayName: String {
        #if DEBUG
        if let debugLanguageModeOverride = appState.debugLanguageModeOverride {
            return languageOptionDisplayName(debugLanguageModeOverride)
        }
        #endif

        let resolvedLanguage = appState.languageMode == .system
            ? ForgePlaySystemLanguageResolver.resolvedLanguageMode()
            : appState.languageMode
        return languageOptionDisplayName(resolvedLanguage)
    }

    private var isSystemLanguageResetDisabled: Bool {
        #if DEBUG
        if appState.debugLanguageModeOverride != nil {
            return false
        }
        #endif
        return appState.languageMode == .system
    }

    private var compatibilityDBUpdateDisabledReason: String? {
        if services.compatibilityDBUpdateService.isUpdateInProgress {
            return appState.localizedError(CompatibilityDBUpdateError.updateInProgress)
        }
        if let unavailableError = services.compatibilityDBUpdateService.remoteUpdateUnavailableError {
            return appState.localizedError(unavailableError)
        }

        let trimmedURL = compatibilityDBURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            return appState.localizedError(CompatibilityDBUpdateError.missingFeedURL)
        }

        do {
            _ = try services.compatibilityDBUpdateService.validateFeedURL(URL(string: trimmedURL))
            return nil
        } catch {
            return appState.localizedError(error)
        }
    }

    var body: some View {
        @Bindable var appState = appState
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
        let compatibilityDBUpdateDisabledReason = self.compatibilityDBUpdateDisabledReason
        let isSystemCheckInProgress = services.setupWorkflowCoordinator.isSystemCheckInProgress
        let canCreateSteamPrefix = canRunBundledWindowsRuntime &&
            readiness.rootIssue == nil &&
            appState.selectedRootURL != nil &&
            appState.runtimeExecutableURL != nil &&
            !isCreatingSteamPrefix &&
            !services.steamPrefixLifecycleCoordinator.isBusy
        let canInstallSteam = canRunBundledWindowsRuntime &&
            readiness.rootIssue == nil &&
            readiness.hasSteamPrefix &&
            appState.runtimeExecutableURL != nil &&
            !services.steamPrefixLifecycleCoordinator.isBusy
        let steamInstallActionTitle = readiness.hasSteamExecutable ? "다시 설치" : "설치"

        ForgePageScaffold(
            "환경 설정",
            subtitle: "앱 환경, 실행 데이터, 진단 보존 정책을 관리합니다.",
            systemImage: "gearshape"
        ) {
            SectionHelpButton(section: .settings) {
                presentSheet(.sectionHelp(.settings))
            }
        } content: {
            settingsPanePicker(palette: palette)

            if selectedPane == .general {
                generalPreferencesGrid(palette: palette)
            }

            if selectedPane == .input {
                VStack(alignment: .leading, spacing: ForgePlayLayout.sectionSpacing) {
                    gameInputPreferencesCard(palette: palette)
                    awdlControlPreferencesCard(palette: palette)
                }
            }

            if selectedPane == .environment {

                ForgeCard("설정 상태", systemImage: "list.bullet.rectangle") {
                    VStack(spacing: 0) {
                        SettingStatusRow(
                            title: "앱 데이터 위치",
                            value: rootStatusText,
                            status: rootStatus,
                            buttonTitle: "관리",
                            buttonSystemImage: "folder"
                        ) {
                            presentSheet(.chooseRoot)
                        }
                        Divider()
                        SettingStatusRow(
                            title: "Mac 상태",
                            value: macCheckSummary,
                            status: macCheckStatus,
                            buttonTitle: isSystemCheckInProgress ? "확인 중" : "다시 확인",
                            buttonSystemImage: "checkmark.shield",
                            isDisabled: isSystemCheckInProgress
                        ) {
                            runSystemChecks()
                        }
                        Divider()
                        SettingStatusRow(
                            title: PairedTerm.gameEngine.displayName,
                            value: runtimeStatusText,
                            status: runtimeStatus,
                            buttonTitle: appState.runtimeExecutableURL == nil ? "확인" : "Apple D3DMetal 보조 렌더러",
                            buttonSystemImage: "shippingbox",
                            isDisabled: !canImportAppleSupplementalRenderer
                        ) {
                            presentSheet(.importAppleSupplementalRenderer)
                        }
                        Divider()
                        SettingStatusRow(
                            title: PairedTerm.executionEnvironment.displayName,
                            value: steamPrefixStatusText,
                            status: steamPrefixStatus,
                            buttonTitle: "만들기",
                            buttonSystemImage: "externaldrive.badge.plus",
                            isDisabled: !canCreateSteamPrefix,
                            disabledReason: steamPrefixDisabledReason
                        ) {
                            requestSteamPrefixCreation()
                        }
                        Divider()
                        SettingStatusRow(
                            title: "Windows용 Steam",
                            value: steamStatusText,
                            status: steamStatus,
                            buttonTitle: steamInstallActionTitle,
                            buttonSystemImage: "square.and.arrow.down",
                            isDisabled: !canInstallSteam,
                            disabledReason: steamInstallDisabledReason
                        ) {
                            presentSheet(.chooseSteamInstaller)
                        }
                        Divider()
                        SettingStatusRow(
                            title: "Steam 참고 목록",
                            value: gameListStatusText,
                            status: gameListStatus,
                            buttonTitle: "Steam 실행",
                            buttonSystemImage: "play.circle"
                        ) {
                            openMainWindow(section: .steamLaunch)
                        }
                    }

                    ResponsiveActionRow {
                        ThemedActionButton(
                            title: "문제 분석 기록 열기",
                            systemImage: "folder",
                            prominence: .secondary,
                            controlSize: .small
                        ) {
                            openLogsFolder()
                        }
                        .frame(minWidth: 164, idealWidth: 190, maxWidth: 240)

                        ThemedActionButton(
                            title: "설정으로 이동",
                            systemImage: "wand.and.sparkles",
                            prominence: .secondary,
                            controlSize: .small
                        ) {
                            openMainWindow(section: .setup)
                        }
                        .frame(minWidth: 164, idealWidth: 190, maxWidth: 240)
                    }
                    .padding(.top, 8)
                }

                RuntimeDependencyWorkflowCard(sheetPresenter: presentSheet)

                SetupProgressResetCard {
                    refreshReadiness()
                }
            }

            if selectedPane == .maintenance {
                ForgeCard("호환성 정보 업데이트", systemImage: "arrow.down.doc") {
                    Text(appState.localized("서명된 HTTPS index.json의 호환성 안내만 저장합니다. 실행 설정을 자동 변경하지 않으며, 진단 화면에서 사용자가 확인할 권장 조치로만 제시합니다."))
                        .font(.callout)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(appState.localized("호환성 DB 주소"), text: $compatibilityDBURL)
                        .textFieldStyle(.roundedBorder)
                    ResponsiveActionRow {
                        ThemedActionButton(
                            title: services.compatibilityDBUpdateService.isUpdateInProgress
                                ? "업데이트 중"
                                : "호환성 정보 업데이트",
                            systemImage: "arrow.clockwise",
                            prominence: .primary,
                            isDisabled: compatibilityDBUpdateDisabledReason != nil
                        ) {
                            updateCompatibilityDB()
                        }
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)

                        Text(appState.localizedFormat("%d개 호환성 정보 저장됨", compatibilityRecipes.count))
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let compatibilityDBUpdateDisabledReason {
                        Text(compatibilityDBUpdateDisabledReason)
                            .font(.caption)
                            .foregroundStyle(palette.warning)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !compatibilityDBStatusMessage.isEmpty {
                        Text(compatibilityDBStatusMessage)
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ForgeCard("문제 분석 기록 보존", systemImage: "clock.arrow.circlepath") {
                    Toggle(appState.localized("오래된 문제 분석 기록 자동 정리"), isOn: $appState.isLogAutoCleanupEnabled)
                    Stepper(value: $appState.logRetentionDays, in: 1...365) {
                        Text(appState.localizedFormat("최근 %d일 보존", appState.logRetentionDays))
                    }
                    Stepper(value: $appState.launchLogLimit, in: 1...200) {
                        Text(appState.localizedFormat("Steam 실행 로그 세트 최대 %d개 보존", appState.launchLogLimit))
                    }
                    ResponsiveActionRow {
                        ThemedActionButton(
                            title: "보존 설정 저장",
                            systemImage: "checkmark",
                            prominence: .secondary
                        ) {
                            saveMaintenanceSettings()
                        }
                        .frame(minWidth: 150, idealWidth: 170, maxWidth: 220)

                        ThemedActionButton(
                            title: isCleaningLogs ? "정리 중" : "지금 정리",
                            systemImage: "trash",
                            prominence: .secondary
                        ) {
                            isShowingLogCleanupConfirmation = true
                        }
                        .disabled(isCleaningLogs)
                        .frame(minWidth: 120, idealWidth: 140, maxWidth: 180)
                    }
                    if !logCleanupStatusMessage.isEmpty {
                        Text(logCleanupStatusMessage)
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if selectedPane == .environment {
                ForgeCard("설치와 권한", systemImage: "checkmark.shield") {
                    TermLabel(term: .gameEngine)
                    TermLabel(term: .executionEnvironment)
                    TermLabel(term: .requiredComponent)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        StatusBadge(label: bundledRuntimeCapabilityLabel, status: bundledRuntimeCapabilityStatus)
                        Text(appState.localized(bundledRuntimeCapabilityDetailKey))
                            .font(.callout)
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    Text(appState.localized("ForgePlay는 앱에 포함된 ForgePlay Runtime을 실행 엔진으로 사용합니다. 사용자가 Apple 공식 Evaluation environment DMG/redist를 선택하면 D3DMetal 보조 렌더러만 앱 데이터 영역에 가져와 게임 실행 시 합성하며, Steam 클라이언트의 기본 Wine 모듈은 덮어쓰지 않습니다. Steam 로그인은 Steam 창에서 직접 진행하며 ForgePlay는 Steam 계정 정보를 저장하지 않습니다."))
                        .font(.callout)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if selectedPane == .about {
                ForgeCard("라이선스와 법무 고지", systemImage: "doc.plaintext") {
                    VStack(alignment: .leading, spacing: 8) {
                        legalRow("독립 배포 빌드는 ForgePlay Runtime과 필요한 실행 구성요소를 앱 번들 안에 포함하는 self-contained 구조입니다.")
                        legalRow("Wine 기반 런타임을 포함하거나 제공할 때는 Wine 버전, 소스 URL, 라이선스 전문, 수정 사항, 빌드/소스 제공 정보를 함께 고지합니다.")
                        legalRow("Steam 계정, 비밀번호, Steam Guard 코드는 저장하거나 요청하지 않습니다.")
                        legalRow("Microsoft Runtime 설치 파일은 앱 서버에서 호스팅하지 않고 공식 페이지 또는 사용자가 가진 설치 파일을 사용합니다.")
                        legalRow("Apple Foundation Models는 로컬 보조 진단에만 사용합니다. 권장 조치는 앱의 허용 목록과 사용자 확인을 모두 거친 뒤에만 적용됩니다.")
                        legalRow("ForgePlay의 공식 배포 형식은 Developer ID로 서명하고 Apple 공증을 거친 DMG입니다.")
                    }
                    ResponsiveActionRow {
                        ForEach(LegalDocument.allCases) { document in
                            ThemedActionButton(
                                title: document.titleKey,
                                systemImage: document.systemImage,
                                prominence: .secondary,
                                controlSize: .small
                            ) {
                                openLegalDocument(document)
                            }
                            .frame(minWidth: 130, idealWidth: 160, maxWidth: 220)
                        }
                    }
                    if !legalDocumentStatusMessage.isEmpty {
                        Text(legalDocumentStatusMessage)
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .task {
            if performsInitialWorkflowRefresh {
                do {
                    try await refreshSetupWorkflowUntilCurrent()
                } catch is CancellationError {
                    return
                } catch {
                    appState.setError(error)
                }
            }
            loadSettings()
            if appState.hasEnabledGameInputEventTapProtection {
                services.refreshGameInputProtectionAuthorizationStatus()
            }
            services.synchronizeGameInputProtectionPolicy(from: appState)
            await services.awdlControlService.refresh()
            if performsInitialWorkflowRefresh {
                refreshReadiness()
            }
        }
        .onChange(of: selectedPane) { _, pane in
            guard pane == .input else { return }
            Task { @MainActor in
                await services.awdlControlService.refresh()
            }
        }
        .onChange(of: setupReadinessObservationKey) { _, _ in
            if performsInitialWorkflowRefresh { refreshReadiness() }
        }
        .confirmationDialog(
            appState.localized("Steam 프리픽스를 만들까요?"),
            isPresented: $isShowingSteamPrefixConfirmation,
            titleVisibility: .visible
        ) {
            Button(appState.localized("내부 저장소에 만들기")) {
                createSteamPrefix()
            }
            Button(appState.localized("취소"), role: .cancel) {}
        } message: {
            Text(appState.localizedFormat(
                "대상 위치:\n%@\n\n처음 생성은 Steam 프리픽스 초기화 때문에 몇 분 걸릴 수 있습니다. ForgePlay가 먼저 포함 Runtime 실행 여부를 확인한 뒤 진행합니다.",
                steamPrefixTargetPath
            ))
        }
        .confirmationDialog(
            appState.localized("문제 분석 기록을 지금 정리할까요?"),
            isPresented: $isShowingLogCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button(appState.localized("설정 기준으로 기록 삭제"), role: .destructive) {
                cleanupLogsNow()
            }
            Button(appState.localized("취소"), role: .cancel) {}
        } message: {
            Text(appState.localizedFormat(
                "최근 %d일과 Steam 실행 로그 세트 최대 %d개 보존 기준을 적용합니다. 삭제된 진단 기록은 되돌릴 수 없으므로 필요한 지원 번들을 먼저 생성하세요.",
                appState.logRetentionDays,
                appState.launchLogLimit
            ))
        }
        .preferredColorScheme(appState.themeMode.preferredColorScheme)
        .tint(palette.primary)
        .background(palette.background.ignoresSafeArea())
    }

    private func settingsPanePicker(palette: ForgePlayPalette) -> some View {
        Picker(appState.localized("설정 영역"), selection: $selectedPane) {
            ForEach(SettingsPane.allCases) { pane in
                Text(appState.localized(pane.title)).tag(pane)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 680, alignment: .leading)
        .tint(palette.primary)
        .accessibilityLabel(appState.localized("설정 영역"))
    }

    private var languageOptionColumns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: languageOptionMinimumWidth),
                spacing: 8,
                alignment: .topLeading
            )
        ]
    }

    private func languageSelectionOptions(palette: ForgePlayPalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appState.localized("앱 언어"))
                .font(.callout.weight(.semibold))
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: languageOptionColumns, alignment: .leading, spacing: 8) {
                ForEach(ForgePlayLanguageMode.allCases) { language in
                    languageOptionButton(language, palette: palette)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .accessibilityLabel(appState.localized("앱 언어"))
    }

    private func languageOptionButton(_ language: ForgePlayLanguageMode, palette: ForgePlayPalette) -> some View {
        let isSelected = appState.languageMode == language

        return Button {
            appState.saveUserPreferencesAfterMutation(to: modelContext) {
                appState.setLanguageModeFromUserSelection(language)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? palette.primary : palette.secondaryText)
                    .frame(width: 18, alignment: .center)
                    .padding(.top, 1)

                Text(languageOptionDisplayName(language))
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(palette.text)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(isSelected ? palette.primary.opacity(0.12) : palette.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? palette.primary.opacity(0.5) : palette.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(ForgeActionButtonStyle(cornerRadius: 8))
        .accessibilityLabel(languageOptionDisplayName(language))
        .accessibilityValue(Text(isSelected ? appState.localized("현재 선택") : ""))
    }

    private func generalPreferencesGrid(palette: ForgePlayPalette) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 440), spacing: ForgePlayLayout.sectionSpacing)
            ],
            alignment: .leading,
            spacing: ForgePlayLayout.sectionSpacing
        ) {
            languagePreferencesCard(palette: palette)
            VStack(alignment: .leading, spacing: ForgePlayLayout.sectionSpacing) {
                appearancePreferencesCard
                aiDiagnosticsPreferencesCard(palette: palette)
            }
        }
    }

    private func gameInputPreferencesCard(palette: ForgePlayPalette) -> some View {
        ForgeCard("게임 입력 및 macOS 단축키 보호", systemImage: "keyboard.badge.ellipsis") {
            Text(appState.localized("일반 Steam과 Steam 호환성 실행에 공통으로 적용됩니다. 각 Steam 세션은 시작 시점 설정의 변경 불가능한 스냅샷을 사용하므로 여기서 바꾼 내용은 다음 실행부터 적용됩니다. 필터는 관리되는 세션의 정상 종료가 확인되면 해제됩니다. 실행 중 필터가 상실되면 즉시 해제한 뒤 관리되는 Steam 세션을 자동 종료하고 입력 상태를 복원합니다."))
                .font(.callout)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            Text(appState.localized(
                "입력 보호는 선택 기능입니다. Steam 실행이나 게임 키 바인딩 자체에는 필요하지 않으며, ForgePlay가 보조키를 변환하고 macOS 단축키를 차단할 때만 손쉬운 사용과 입력 모니터링 권한을 사용합니다."
            ))
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 10) {
                StatusBadge(
                    label: gameInputProtectionStatusLabel,
                    status: gameInputProtectionStatus
                )
            }

            if gameInputProtectionNeedsAuthorization {
                GameInputProtectionAuthorizationPanel(
                    disablePermissionRequiredProtection:
                        disablePermissionRequiredGameInputProtection
                )
            }

            if !supportsGameInputProtectionInCurrentBuild {
                Text(appState.localized("이 빌드에서는 게임 입력 보호를 사용할 수 없습니다."))
                    .font(.caption)
                    .foregroundStyle(palette.warning)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle(
                appState.localized(
                    "게임이 전면일 때 macOS 포인터 숨기기 (베타)"
                ),
                isOn: Binding(
                    get: {
                        appState.hidesPointerWhileManagedGameFrontmost
                    },
                    set: { value in
                        saveGameInputPreferences {
                            appState.hidesPointerWhileManagedGameFrontmost =
                                value
                        }
                    }
                )
            )
            .disabled(!supportsGameInputProtectionInCurrentBuild)

            Text(appState.localized("실험 단계의 기능으로 동작을 보장하지 않습니다. 관리 중인 Steam 또는 게임이 전면에 있을 때 공개 macOS API를 통해 시스템 포인터 숨김을 요청합니다. 포인터 잠금, 상대 이동, 입력 지연 개선 기능은 제공하지 않습니다. macOS에서는 포인터가 실제로 숨겨졌는지 앱이 확인할 수 없으며, ForgePlay가 백그라운드에 있으면 적용되지 않을 수 있습니다."))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle(appState.localized("게임용 보조키 매핑 사용"), isOn: Binding(
                get: { appState.isGameInputModifierMappingEnabled },
                set: { isEnabled in
                    saveGameInputPreferences {
                        appState.isGameInputModifierMappingEnabled = isEnabled
                    }
                }
            ))
            .disabled(!supportsGameInputProtectionInCurrentBuild)

            Text(appState.localized("관리되는 게임이 전면일 때 macOS 호스트의 물리 Command·Option·Control 이벤트를 Ctrl·Alt 또는 전달 안 함으로 각각 독립 변환하려고 시도합니다. 여러 키를 같은 대상으로 연결할 수 있고 Windows 키는 만들지 않습니다. 실제 Wine·게임 자식의 수신은 별도로 확인하지 않으며 문자 키나 게임 내부 단축키를 바꾸지 않습니다."))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(HostModifierKey.allCases, id: \.self) { hostKey in
                    HStack(spacing: 12) {
                        Text(appState.localized(hostModifierTitle(hostKey)))
                            .frame(minWidth: 120, alignment: .leading)
                        Picker(
                            appState.localized(hostModifierTitle(hostKey)),
                            selection: Binding(
                                get: { appState.gameInputModifierBinding(for: hostKey) },
                                set: { binding in
                                    saveGameInputPreferences {
                                        appState.setGameInputModifierBinding(hostKey, to: binding)
                                    }
                                }
                            )
                        ) {
                            ForEach(
                                [GameInputModifierBinding.control, .alt, .disabled],
                                id: \.self
                            ) { binding in
                                Text(appState.localized(gameInputModifierTitle(binding)))
                                    .tag(binding)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260, alignment: .leading)
                    }
                }
            }
            .disabled(
                !supportsGameInputProtectionInCurrentBuild ||
                    !appState.isGameInputModifierMappingEnabled
            )

            Divider()

            Toggle(appState.localized("게임 중 앱 종료·창 관리 단축키 차단"), isOn: Binding(
                get: { appState.blocksGameAppWindowManagementShortcuts },
                set: { value in
                    saveGameInputPreferences {
                        appState.blocksGameAppWindowManagementShortcuts = value
                    }
                }
            ))
            .disabled(!supportsGameInputProtectionInCurrentBuild)

            Text(appState.localized("Command-Q·W·H·M을 대상으로 합니다."))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)

            Toggle(appState.localized("게임 중 앱 전환·검색 단축키 차단"), isOn: Binding(
                get: { appState.blocksGameAppSwitchingShortcuts },
                set: { value in
                    saveGameInputPreferences {
                        appState.blocksGameAppSwitchingShortcuts = value
                    }
                }
            ))
            .disabled(!supportsGameInputProtectionInCurrentBuild)

            Text(appState.localized("Command-Tab·Shift-Command-Tab과 Command-Space를 대상으로 합니다."))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)

            Toggle(appState.localized("게임 중 Mission Control·Spaces 키보드 단축키 차단"), isOn: Binding(
                get: { appState.blocksGameMissionControlSpaceShortcuts },
                set: { value in
                    saveGameInputPreferences {
                        appState.blocksGameMissionControlSpaceShortcuts = value
                    }
                }
            ))
            .disabled(!supportsGameInputProtectionInCurrentBuild)

            Text(appState.localized("Control-방향키와 macOS가 일반 키 이벤트로 전달하는 F3·F11을 대상으로 합니다. 트랙패드 제스처는 대상이 아닙니다."))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)

            Toggle(appState.localized("게임 중 macOS 기본 스크린샷 단축키 차단"), isOn: Binding(
                get: { appState.blocksGameScreenshotShortcuts },
                set: { value in
                    saveGameInputPreferences { appState.blocksGameScreenshotShortcuts = value }
                }
            ))
            .disabled(!supportsGameInputProtectionInCurrentBuild)

            Text(appState.localized("스크린샷 옵션은 Command-Shift-3·4·5·6과 Control 변형만 대상으로 합니다. 다른 캡처 앱·화면 공유·Dock·트랙패드 제스처는 차단하지 않습니다. Option-Command-Escape 강제 종료, Control-Command-Q 화면 잠금, 전원·비상 입력은 항상 허용합니다."))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            if gameInputProtectionNeedsAuthorization {
                Text(appState.localized(gameInputProtectionAuthorizationRequirementMessage))
                    .font(.caption)
                    .foregroundStyle(palette.warning)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var supportsGameInputProtectionInCurrentBuild: Bool {
        GameInputProtectionBuildCapability.isSupportedInCurrentBuild
    }

    private var gameInputProtectionIsAuthorized: Bool {
        guard supportsGameInputProtectionInCurrentBuild else { return false }
        switch gameInputProtectionAuthorizationStatus {
        case .authorized:
            return true
        case .accessibilityRequired,
             .inputMonitoringRequired,
             .accessibilityAndInputMonitoringRequired:
            return false
        }
    }

    private var gameInputProtectionNeedsAuthorization: Bool {
        supportsGameInputProtectionInCurrentBuild &&
            appState.hasEnabledGameInputEventTapProtection &&
            !gameInputProtectionIsAuthorized
    }

    private var gameInputProtectionStatus: CheckStatus {
        guard supportsGameInputProtectionInCurrentBuild else { return .warning }
        guard appState.hasEnabledGameInputProtection else { return .unknown }
        guard appState.hasEnabledGameInputEventTapProtection else { return .ok }
        return gameInputProtectionIsAuthorized ? .ok : .warning
    }

    private var gameInputProtectionStatusLabel: String {
        if !supportsGameInputProtectionInCurrentBuild {
            return appState.localized("이 빌드에서 지원 안 함")
        }
        if !appState.hasEnabledGameInputProtection {
            return appState.localized("입력 보호 꺼짐")
        }
        if !appState.hasEnabledGameInputEventTapProtection {
            return appState.localized("포인터 숨김 사용 준비됨")
        }
        switch gameInputProtectionAuthorizationStatus {
        case .authorized:
            return appState.localized("입력 보호 사용 준비됨")
        case .accessibilityRequired:
            return appState.localized("손쉬운 사용 권한 필요")
        case .inputMonitoringRequired:
            return appState.localized("입력 모니터링 권한 필요")
        case .accessibilityAndInputMonitoringRequired:
            return appState.localized("손쉬운 사용·입력 모니터링 권한 필요")
        }
    }

    private var gameInputProtectionAuthorizationStatus:
        GameInputProtectionAuthorizationStatus {
        services.gameInputProtectionAuthorizationStatus
    }

    private var gameInputProtectionAuthorizationRequirementMessage: String {
        switch gameInputProtectionAuthorizationStatus {
        case .authorized:
            return "게임 입력 보호 권한이 준비되었습니다."
        case .accessibilityRequired:
            return "선택한 보호 기능에는 macOS 손쉬운 사용 권한이 필요합니다. 권한이 없으면 해당 설정으로 Steam을 실행하지 않습니다."
        case .inputMonitoringRequired:
            return "선택한 보호 기능에는 macOS 입력 모니터링 권한이 필요합니다. 권한이 없으면 해당 설정으로 Steam을 실행하지 않습니다."
        case .accessibilityAndInputMonitoringRequired:
            return "선택한 보호 기능에는 macOS 손쉬운 사용 및 입력 모니터링 권한이 필요합니다. 권한이 없으면 해당 설정으로 Steam을 실행하지 않습니다."
        }
    }

    private func saveGameInputPreferences(_ mutation: () -> Void) {
        let warning = appState.saveUserPreferencesAfterMutation(
            to: modelContext,
            mutation
        )
        guard warning == nil else { return }
        services.synchronizeGameInputProtectionPolicy(from: appState)
        if appState.hasEnabledGameInputEventTapProtection {
            services.refreshGameInputProtectionAuthorizationStatus()
        }
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

    private func hostModifierTitle(_ key: HostModifierKey) -> String {
        switch key {
        case .command: "물리 Command 키"
        case .option: "물리 Option 키"
        case .control: "물리 Control 키"
        }
    }

    private func gameInputModifierTitle(_ binding: GameInputModifierBinding) -> String {
        switch binding {
        case .control: "Ctrl로 전달"
        case .alt: "Alt로 전달"
        case .disabled: "전달 안 함"
        }
    }

    private func awdlControlPreferencesCard(
        palette: ForgePlayPalette
    ) -> some View {
        let control = services.awdlControlService
        return ForgeCard(
            "게임 네트워크 · AWDL 제어 (기본 켬 · 베타)",
            systemImage: "network.badge.shield.half.filled"
        ) {
            Text(appState.localized("AWDL은 AirDrop·AirPlay·Sidecar·Handoff 같은 Apple 기기 간 기능에 쓰이는 무선 인터페이스입니다. 일부 환경에서는 게임 중 간헐적인 무선 지연에 영향을 줄 수 있어 수동으로 끄고 다시 켤 수 있게 합니다. 지연 개선을 보장하지 않으며 시스템 전체에 적용됩니다."))
                .font(.callout)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                awdlStatusRow(
                    title: "기본 상태",
                    label: "AWDL 켜짐",
                    status: .ok,
                    palette: palette
                )
                awdlStatusRow(
                    title: "현재 시스템 상태",
                    label: awdlControlStatusLabel,
                    status: awdlControlStatus,
                    palette: palette
                )
            }

            Text(appState.localized("AWDL 제어 도우미를 처음 활성화하면 AWDL을 켜고 실제 인터페이스 상태를 다시 확인합니다. 이후에는 위의 현재 시스템 상태가 실제 켜짐·꺼짐 여부를 표시합니다."))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            Text(appState.localized("AWDL을 끄면 AirDrop·AirPlay·Sidecar·Handoff와 연속성 기능이 중단될 수 있습니다. 꺼진 상태는 ForgePlay를 종료해도 유지되므로 게임을 마친 뒤 반드시 다시 켜세요."))
                .font(.caption)
                .foregroundStyle(palette.warning)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            ResponsiveActionRow {
                if control.registrationState == .notRegistered ||
                    control.registrationState == .notFound {
                    ThemedActionButton(
                        title: "AWDL 제어 도우미 활성화",
                        systemImage: "person.badge.key",
                        prominence: .secondary,
                        isDisabled: control.isWorking ||
                            !AWDLControlBuildCapability.isSupportedInCurrentBuild,
                        controlSize: .small
                    ) {
                        Task { @MainActor in
                            await registerAWDLControlHelper()
                        }
                    }
                    .frame(minWidth: 180, idealWidth: 230, maxWidth: 300)
                }

                if control.registrationState == .requiresApproval {
                    ThemedActionButton(
                        title: "로그인 항목 설정 열기",
                        systemImage: "gearshape",
                        prominence: .secondary,
                        controlSize: .small
                    ) {
                        control.openApprovalSettings()
                    }
                    .frame(minWidth: 170, idealWidth: 210, maxWidth: 280)
                }

                ThemedActionButton(
                    title: "AWDL 켜기",
                    systemImage: "wifi",
                    prominence: control.interfaceState == .enabled
                        ? .primary
                        : .secondary,
                    isDisabled: awdlCommandIsDisabled ||
                        control.interfaceState == .enabled,
                    controlSize: .small
                ) {
                    Task { @MainActor in
                        await setAWDLInterfaceEnabled(true)
                    }
                }
                .frame(minWidth: 130, idealWidth: 170, maxWidth: 220)

                ThemedActionButton(
                    title: "AWDL 끄기",
                    systemImage: "wifi.slash",
                    prominence: control.interfaceState == .disabled
                        ? .primary
                        : .secondary,
                    isDisabled: awdlCommandIsDisabled ||
                        control.interfaceState == .disabled,
                    controlSize: .small
                ) {
                    Task { @MainActor in
                        await setAWDLInterfaceEnabled(false)
                    }
                }
                .frame(minWidth: 130, idealWidth: 170, maxWidth: 220)

                ThemedActionButton(
                    title: "AWDL 상태 새로고침",
                    systemImage: "arrow.clockwise",
                    prominence: .secondary,
                    isDisabled: control.isWorking,
                    controlSize: .small
                ) {
                    Task { @MainActor in
                        await control.refresh()
                    }
                }
                .frame(minWidth: 160, idealWidth: 210, maxWidth: 280)
            }

            if let error = control.lastError {
                Text(appState.localizedError(error))
                    .font(.caption)
                    .foregroundStyle(palette.warning)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func awdlStatusRow(
        title: String,
        label: String,
        status: CheckStatus,
        palette: ForgePlayPalette
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(appState.localized(title))
                .font(.callout.weight(.semibold))
                .foregroundStyle(palette.text)
            Spacer(minLength: 12)
            StatusBadge(label: label, status: status)
            if services.awdlControlService.isWorking,
               title == "현재 시스템 상태" {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        appState.localized("AWDL 상태 변경 중")
                    )
            }
        }
    }

    private var awdlCommandIsDisabled: Bool {
        let control = services.awdlControlService
        return !AWDLControlBuildCapability.isSupportedInCurrentBuild ||
            control.isWorking
    }

    private var awdlControlStatus: CheckStatus {
        let control = services.awdlControlService
        switch control.registrationState {
        case .unsupported, .notFound, .requiresApproval:
            return .warning
        case .notRegistered:
            return .unknown
        case .enabled:
            return control.interfaceState == .unavailable ? .warning : .ok
        }
    }

    private var awdlControlStatusLabel: String {
        let control = services.awdlControlService
        if control.isWorking { return appState.localized("AWDL 상태 변경 중") }
        switch control.registrationState {
        case .unsupported:
            return appState.localized("이 빌드에서 AWDL 제어 지원 안 함")
        case .notRegistered:
            return appState.localized("AWDL 제어 도우미 미설정")
        case .requiresApproval:
            return appState.localized("AWDL 제어 도우미 승인 필요")
        case .notFound:
            return appState.localized("AWDL 제어 도우미 없음")
        case .enabled:
            switch control.interfaceState {
            case .enabled:
                return appState.localized("AWDL 켜짐")
            case .disabled:
                return appState.localized("AWDL 꺼짐")
            case .unavailable:
                return appState.localized("AWDL 상태 확인 필요")
            }
        }
    }

    private func registerAWDLControlHelper() async {
        do {
            try await services.awdlControlService.registerHelper(
                defaultInterfaceEnabled: true
            )
            appState.setNotice(
                appState.localized("AWDL 제어 도우미를 활성화하고 AWDL을 켰습니다."),
                kind: .success
            )
        } catch AWDLControlError.helperRequiresApproval {
            services.awdlControlService.openApprovalSettings()
            appState.setNotice(
                appState.localizedError(AWDLControlError.helperRequiresApproval),
                kind: .warning
            )
        } catch {
            appState.setNotice(appState.localizedError(error), kind: .failure)
        }
    }

    private func setAWDLInterfaceEnabled(_ enabled: Bool) async {
        do {
            try await services.awdlControlService.setInterfaceEnabled(enabled)
            appState.setNotice(
                appState.localized(enabled ? "AWDL을 켰습니다." : "AWDL을 껐습니다."),
                kind: enabled ? .success : .warning
            )
        } catch AWDLControlError.helperRequiresApproval {
            services.awdlControlService.openApprovalSettings()
            appState.setNotice(
                appState.localizedError(AWDLControlError.helperRequiresApproval),
                kind: .warning
            )
        } catch {
            appState.setNotice(appState.localizedError(error), kind: .failure)
        }
    }

    private func languagePreferencesCard(palette: ForgePlayPalette) -> some View {
        ForgeCard("앱 언어", systemImage: "globe") {
            languageControlPanel(palette: palette)
        }
    }

    private var appearancePreferencesCard: some View {
        ForgeCard("화면 스타일", systemImage: "paintpalette") {
            Picker(appState.localized("색상 스타일"), selection: Binding(
                get: { appState.themeMode },
                set: { mode in
                    appState.saveUserPreferencesAfterMutation(to: modelContext) {
                        appState.themeMode = mode
                    }
                }
            )) {
                ForEach(ForgePlayThemeMode.allCases) { mode in
                    Text(appState.localized(mode.label)).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Toggle(appState.localized("고급 정보 표시"), isOn: Binding(
                get: { appState.isAdvancedModeEnabled },
                set: { isEnabled in
                    appState.saveUserPreferencesAfterMutation(to: modelContext) {
                        appState.isAdvancedModeEnabled = isEnabled
                    }
                }
            ))
        }
    }

    private func aiDiagnosticsPreferencesCard(palette: ForgePlayPalette) -> some View {
        let availability = services.llmService.availability

        return ForgeCard(PairedTerm.aiDiagnostics.beginner, systemImage: "brain") {
            Toggle(appState.localized("AI 문제 진단(베타) 사용"), isOn: Binding(
                get: { appState.isLLMDiagnosticsEnabled },
                set: {
                    saveAIDiagnosticsEnabled($0)
                }
            ))
            Text(appState.localized("기본값은 꺼짐입니다. 켜면 로그를 외부 서버로 보내지 않고, 분석 전 가려진 내용을 확인한 뒤 이 Mac의 Apple Foundation Models로만 분석합니다."))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    StatusBadge(label: availability.status.label, status: availability.status)
                    aiProviderText(availability: availability, palette: palette)
                }
                VStack(alignment: .leading, spacing: 8) {
                    StatusBadge(label: availability.status.label, status: availability.status)
                    aiProviderText(availability: availability, palette: palette)
                }
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func languageControlPanel(palette: ForgePlayPalette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            languageSummary(palette: palette)
            languageSelectionOptions(palette: palette)

            Text(appState.localized("언어를 선택하지 않으면 macOS 시스템 언어를 따릅니다."))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            ThemedActionButton(
                title: "시스템 언어 따르기",
                systemImage: "globe",
                prominence: .secondary,
                isDisabled: isSystemLanguageResetDisabled,
                controlSize: .small
            ) {
                appState.saveUserPreferencesAfterMutation(to: modelContext) {
                    appState.setLanguageModeFromUserSelection(.system)
                }
            }
            .frame(minWidth: 180, idealWidth: 280, maxWidth: 520, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func languageSummary(palette: ForgePlayPalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.localizedFormat("현재 적용 언어: %@", currentLanguageDisplayName))
                .font(.callout.weight(.semibold))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(appState.languageMode == .system
                 ? appState.localized("시스템 언어 따르기")
                 : languageOptionDisplayName(appState.languageMode))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            #if DEBUG
            if let debugLanguageModeOverride = appState.debugLanguageModeOverride,
               !appState.debugAppStoreScreenshotFixture {
                Text(appState.localizedFormat(
                    "언어 미리보기 적용 중: %@",
                    languageOptionDisplayName(debugLanguageModeOverride)
                ))
                    .font(.caption)
                    .foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func languageOptionDisplayName(_ language: ForgePlayLanguageMode) -> String {
        language == .system ? appState.localized(language.labelKey) : language.labelKey
    }

    private var macCheckStatus: CheckStatus {
        appState.systemCheckSummary.displayStatus
    }

    private var isAppStoreScreenshotFixture: Bool {
        #if DEBUG
        return appState.debugAppStoreScreenshotFixture
        #else
        return false
        #endif
    }

    private var canRunBundledWindowsRuntime: Bool {
        isAppStoreScreenshotFixture || ForgePlayRuntimeCapabilityPolicy.canRunBundledWindowsRuntime
    }

    private var canImportAppleSupplementalRenderer: Bool {
        isAppStoreScreenshotFixture || ForgePlayRuntimeCapabilityPolicy.canImportAppleSupplementalRenderer
    }

    private var bundledRuntimeUnavailableReason: String? {
        bundledRuntimeUnavailableReasonKey.map(appState.localized)
    }

    private var bundledRuntimeUnavailableReasonKey: String? {
        canRunBundledWindowsRuntime
            ? nil
            : ForgePlayRuntimeCapabilityPolicy.unavailableReasonKey
    }

    private var bundledRuntimeCapabilityStatus: CheckStatus {
        canRunBundledWindowsRuntime ? .ok : .warning
    }

    private var bundledRuntimeCapabilityLabel: String {
        canRunBundledWindowsRuntime
            ? "ForgePlay Runtime 사용 가능"
            : "ForgePlay Runtime 필요"
    }

    private var bundledRuntimeCapabilityDetailKey: String {
        canRunBundledWindowsRuntime
            ? "Windows용 Steam을 실행할 준비가 되었습니다."
            : ForgePlayRuntimeCapabilityPolicy.unavailableReasonKey
    }

    private var rootStatus: CheckStatus {
        if isAppStoreScreenshotFixture { return .ok }
        if readiness.rootIssue != nil { return .error }
        return appState.selectedRootURL == nil ? .warning : .ok
    }

    private var rootStatusText: String {
        #if DEBUG
        if isAppStoreScreenshotFixture {
            return appState.selectedRootURL?.path ?? ForgePlayDevelopmentFixturePaths.appStoreScreenshotRootPath
        }
        #endif
        if let issue = readiness.rootIssue {
            return appState.localizedError(issue)
        }
        return appState.selectedRootURL?.path ?? appState.localized("앱 데이터 위치를 준비하는 중입니다.")
    }

    private var macCheckSummary: String {
        let summary = appState.systemCheckSummary
        if summary.phase == .unverified {
            return appState.localized("아직 Mac 상태를 확인하지 않았습니다.")
        }
        if !summary.blockingResults.isEmpty {
            return summary.blockingResults.map { appState.localized($0.detail) }.joined(separator: " ")
        }
        return summary.phase == .readyWithWarnings
            ? appState.localized("기본 조건을 만족하며 확인할 권장 사항이 있습니다.")
            : appState.localized("기본 조건을 만족합니다.")
    }

    private var runtimeStatus: CheckStatus {
        if isAppStoreScreenshotFixture { return .ok }
        if !canRunBundledWindowsRuntime { return .warning }
        guard appState.runtimeExecutableURL != nil else { return .warning }
        guard let runtimeSystemCheck else { return .unknown }
        switch runtimeSystemCheck.status {
        case .error:
            return .error
        case .unknown:
            return .unknown
        case .ok:
            return .ok
        case .warning:
            guard let rendererInspection = readiness.rendererInspection else { return .warning }
            if rendererInspection.effectiveRecoveryKind == .runtimeUnavailable ||
                rendererInspection.requiresRepair {
                return .error
            }
            if rendererInspection.requiresApply || rendererInspection.status != .ok {
                return .warning
            }
            return .ok
        }
    }

    private var steamPrefixStatus: CheckStatus {
        if isAppStoreScreenshotFixture { return .ok }
        if !canRunBundledWindowsRuntime { return .warning }
        if readiness.rootIssue != nil { return .error }
        if readiness.steamPrefixIssue != nil { return .error }
        return readiness.hasSteamPrefix ? .ok : .warning
    }

    private var runtimeStatusText: String {
        if isAppStoreScreenshotFixture {
            return appState.localized("ForgePlay Runtime 사용 가능")
        }
        if let bundledRuntimeUnavailableReason {
            return bundledRuntimeUnavailableReason
        }
        guard appState.runtimeExecutableURL != nil else {
            return appState.localized("ForgePlay Runtime을 확인하지 못했습니다.")
        }
        guard let runtimeSystemCheck else {
            return appState.localized("ForgePlay Runtime을 확인하는 중입니다.")
        }
        return appState.localized(runtimeSystemCheck.detail)
    }

    private var steamStatusText: String {
        if isAppStoreScreenshotFixture {
            return appState.localized("사용자가 선택한 Steam 라이브러리를 스캔할 준비가 되어 있습니다.")
        }
        if readiness.hasSteamExecutable, let steam = readiness.steamExecutableURL {
            return steam.path
        }
        if !games.isEmpty {
            return appState.localized("Steam 참고 목록이나 외장 라이브러리가 있어도 실행은 Windows용 Steam에서 시작합니다. SteamSetup.exe를 설치하세요.")
        }
        if let installer = appState.steamInstallerURL {
            return appState.localizedFormat("설치 파일은 선택됨: %@. Steam 실행 파일은 아직 찾지 못했습니다.", installer.path)
        }
        return appState.localized("SteamSetup.exe를 선택해 Steam 프리픽스 안에 설치해야 합니다.")
    }

    private var steamPrefixStatusText: String {
        #if DEBUG
        if isAppStoreScreenshotFixture {
            return "\(ForgePlayDevelopmentFixturePaths.appStoreScreenshotRootPath)/Steam Prefix"
        }
        #endif
        if let bundledRuntimeUnavailableReason {
            return bundledRuntimeUnavailableReason
        }
        if let issue = readiness.rootIssue {
            return appState.localizedError(issue)
        }
        if let issue = readiness.steamPrefixIssue {
            return appState.localizedError(issue)
        }
        return readiness.steamPrefixURL?.path ?? appState.localized("Steam 프리픽스 필요")
    }

    private var steamPrefixTargetPath: String {
        if let issue = readiness.rootIssue {
            return appState.localizedError(issue)
        }
        if let url = readiness.steamPrefixTargetURL(selectedRootURL: appState.selectedRootURL) {
            return url.path
        }
        return appState.localized("앱 데이터 위치를 준비하지 못했습니다.")
    }

    private var steamStatus: CheckStatus {
        if isAppStoreScreenshotFixture { return .ok }
        if !canRunBundledWindowsRuntime { return .warning }
        return readiness.hasSteamExecutable ? .ok : .warning
    }

    private var gameListStatusText: String {
        if isAppStoreScreenshotFixture {
            return appState.localized("2개 샘플 Steam 참고 기록이 있습니다.")
        }
        return normalGameListStatus.value
    }

    private var gameListStatus: CheckStatus {
        if isAppStoreScreenshotFixture { return .ok }
        return normalGameListStatus.status
    }

    private var normalGameListStatus: (value: String, status: CheckStatus) {
        (
            value: games.isEmpty ? appState.localized("Steam 참고 기록이 아직 없습니다.") : appState.localizedFormat("%d개 Steam 참고 기록을 찾았습니다.", games.count),
            status: games.isEmpty ? .warning : .ok
        )
    }

    private var steamPrefixDisabledReason: String? {
        if let bundledRuntimeUnavailableReasonKey { return bundledRuntimeUnavailableReasonKey }
        if let issue = readiness.rootIssue { return appState.localizedError(issue) }
        if appState.selectedRootURL == nil { return appState.localized("앱 데이터 위치를 준비하지 못했습니다.") }
        if appState.runtimeExecutableURL == nil { return appState.localized("ForgePlay Runtime을 먼저 확인하세요.") }
        if isCreatingSteamPrefix { return appState.localized("Steam 프리픽스를 만드는 중입니다.") }
        return nil
    }

    private var steamInstallDisabledReason: String? {
        if let bundledRuntimeUnavailableReasonKey { return bundledRuntimeUnavailableReasonKey }
        if let issue = readiness.rootIssue { return appState.localizedError(issue) }
        if readiness.steamPrefixIssue != nil { return appState.localized("Steam 프리픽스를 먼저 복구하세요.") }
        if !readiness.hasSteamPrefix { return appState.localized("먼저 Steam 프리픽스를 만드세요.") }
        if appState.runtimeExecutableURL == nil { return appState.localized("ForgePlay Runtime을 먼저 확인하세요.") }
        return nil
    }

    private func loadSettings() {
        do {
            try appState.loadIfNeeded(from: modelContext)
            let settings = try appState.loadOrCreateSettings(in: modelContext)
            if settings.normalizeAIDiagnosticProviderConfiguration() {
                try modelContext.saveOrRollback()
            }
            compatibilityDBURL = settings.compatibilityDBUpdateURL ?? ""
            compatibilityDBStatusMessage = compatibilityDBStatusText(for: settings)
        } catch {
            appState.setError(error)
        }
    }

    private func aiProviderText(availability: AIDiagnosticProviderAvailability, palette: ForgePlayPalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LLMService.providerName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(appState.localized(availability.message))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshReadiness() {
        do {
            try services.synchronizeSetupWorkflow(
                appState: appState,
                in: modelContext,
                hasSteamReferences: !games.isEmpty
            )
        } catch {
            appState.setError(error)
        }
    }

    private func runSystemChecks() {
        Task {
            let progressNotice = appState.setTask(appState.localized("Mac 상태를 확인하는 중입니다."))
            defer {
                if let progressNotice {
                    appState.clearNotice(id: progressNotice.id)
                }
            }
            do {
                try await refreshSetupWorkflowUntilCurrent()
            } catch is CancellationError {
                return
            } catch {
                appState.setError(error)
            }
        }
    }

    private func refreshSetupWorkflowUntilCurrent() async throws {
        while true {
            try Task.checkCancellation()
            do {
                _ = try await services.refreshSetupWorkflow(
                    appState: appState,
                    in: modelContext,
                    hasSteamReferences: !games.isEmpty
                )
                return
            } catch SetupWorkflowRefreshControlError.superseded {
                guard SetupWorkflowRefreshRetryPolicy.shouldRetryAfterSupersession(
                    outerTaskIsCancelled: Task.isCancelled
                ) else {
                    throw CancellationError()
                }
                await Task.yield()
            }
        }
    }

    private func requestSteamPrefixCreation() {
        if let bundledRuntimeUnavailableReason {
            appState.setNotice(bundledRuntimeUnavailableReason, kind: .warning)
            return
        }
        if let issue = readiness.rootIssue {
            appState.setNotice(appState.localizedError(issue), kind: .failure)
            presentSheet(.chooseRoot)
            return
        }
        guard appState.selectedRootURL != nil else {
            appState.setNotice(appState.localized("앱 데이터 위치를 준비하지 못했습니다."), kind: .warning)
            presentSheet(.chooseRoot)
            return
        }
        guard appState.runtimeExecutableURL != nil else {
            appState.setNotice(appState.localized("Steam 프리픽스를 만들려면 ForgePlay Runtime을 먼저 확인하세요."), kind: .warning)
            return
        }
        isShowingSteamPrefixConfirmation = true
    }

    private func createSteamPrefix() {
        guard !isCreatingSteamPrefix else { return }
        if let bundledRuntimeUnavailableReason {
            appState.setNotice(bundledRuntimeUnavailableReason, kind: .warning)
            return
        }
        guard let runtimeExecutable = appState.runtimeExecutableURL else {
            appState.setNotice(appState.localized("Steam 프리픽스를 만들려면 ForgePlay Runtime을 먼저 확인하세요."), kind: .warning)
            return
        }

        isCreatingSteamPrefix = true
        let targetPath = steamPrefixTargetPath
        appState.setTask(appState.localizedFormat("ForgePlay Runtime을 확인한 뒤 Steam 프리픽스를 초기화합니다: %@", targetPath))
        Task {
            defer { isCreatingSteamPrefix = false }
            do {
                let preparation = try await services.prepareSteamPrefix(
                    runtimeExecutable: runtimeExecutable,
                    synchronizationSelection: appState.wineSynchronizationSelection
                )
                let persistenceWarning = savePrefixRecordWarning(metadata: preparation.metadata)
                let preparationWarning = DiagnosticWarningText.combined(
                    persistenceWarning,
                    preparation.localizedPreviousEnvironmentCleanupWarning(appState: appState)
                )
                refreshReadiness()
                let message = preparation.processResult == nil
                    ? appState.localized("Steam 프리픽스가 이미 준비되어 있습니다.")
                    : appState.localized("Steam 프리픽스를 초기화했습니다.")
                let notice = appState.setNotice(
                    DiagnosticWarningText.combined(message, preparationWarning) ?? message,
                    kind: preparationWarning == nil ? .success : .warning
                )
                clearTaskLater(notice.id)
            } catch {
                appState.setError(error)
            }
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

    private func openLogsFolder() {
        do {
            let logs = try services.pathManager.url(for: .logs)
            appState.openFileURL(logs)
        } catch {
            appState.setError(error)
        }
    }

    private func saveAIDiagnosticsEnabled(_ isEnabled: Bool) {
        let warning = appState.saveUserPreferencesAfterMutation(to: modelContext) {
            appState.isLLMDiagnosticsEnabled = isEnabled
        }
        if let warning {
            statusMessage = warning
        } else {
            statusMessage = isEnabled
                ? appState.localized("AI 문제 진단을 켰습니다. Apple Foundation Models를 사용할 수 있을 때만 실행됩니다.")
                : appState.localized("AI 문제 진단을 껐습니다. 로컬 자동 문제 분석은 계속 사용할 수 있습니다.")
        }
    }

    private func updateCompatibilityDB() {
        guard !services.compatibilityDBUpdateService.isUpdateInProgress else {
            compatibilityDBStatusMessage = appState.localizedError(CompatibilityDBUpdateError.updateInProgress)
            return
        }
        let settings: AppSettingsRecord
        let feedURL: URL
        do {
            settings = try appState.loadOrCreateSettings(in: modelContext)
            let rawURL = URL(string: compatibilityDBURL.trimmingCharacters(in: .whitespacesAndNewlines))
            feedURL = try services.compatibilityDBUpdateService.validateFeedURL(rawURL)
            compatibilityDBURL = feedURL.absoluteString
            settings.compatibilityDBUpdateURL = feedURL.absoluteString
            settings.updatedAt = Date()
            try modelContext.saveOrRollback()
        } catch {
            compatibilityDBStatusMessage = appState.localizedError(error)
            appState.setError(error)
            return
        }

        let progressNotice = appState.setTask(appState.localized("호환성 정보를 업데이트하는 중입니다."))
        Task {
            defer {
                if let progressNotice {
                    appState.clearNotice(id: progressNotice.id)
                }
            }
            do {
                let stagedExistingRecords = compatibilityRecipes.map {
                    CompatibilityRecipeRecordProjection.makeDetachedRecord(from: $0)
                }
                let (result, records) = try await services.compatibilityDBUpdateService.update(
                    from: feedURL,
                    existingRecords: stagedExistingRecords
                )
                try applyCompatibilityDBUpdateRecords(records)
                settings.lastCompatibilityDBUpdateAt = Date()
                settings.lastCompatibilityDBUpdateStatusKind = CompatibilityDBUpdateStatusKind.succeeded.rawValue
                settings.lastCompatibilityDBUpdateImportedCount = result.importedCount
                settings.lastCompatibilityDBUpdateUpdatedCount = result.updatedCount
                settings.lastCompatibilityDBUpdateStatus = "호환성 DB 업데이트 완료: %d개 추가, %d개 갱신"
                compatibilityDBStatusMessage = result.removedCount > 0
                    ? appState.localizedFormat(
                        "호환성 DB 업데이트 완료: %d개 추가, %d개 갱신, %d개 제거",
                        result.importedCount,
                        result.updatedCount,
                        result.removedCount
                    )
                    : compatibilityDBStatusText(for: settings)
                try modelContext.saveOrRollback()
                let notice = appState.setNotice(compatibilityDBStatusMessage, kind: .success)
                clearTaskLater(notice.id)
            } catch let updateError {
                modelContext.rollback()
                let updateMessage = appState.localizedError(updateError)
                var persistenceWarning: String?
                compatibilityDBStatusMessage = updateMessage
                do {
                    let failedSettings = try appState.loadOrCreateSettings(in: modelContext)
                    failedSettings.lastCompatibilityDBUpdateStatusKind = CompatibilityDBUpdateStatusKind.failed.rawValue
                    failedSettings.lastCompatibilityDBUpdateImportedCount = nil
                    failedSettings.lastCompatibilityDBUpdateUpdatedCount = nil
                    failedSettings.lastCompatibilityDBUpdateStatus = "마지막 호환성 DB 업데이트가 실패했습니다."
                    try modelContext.saveOrRollback()
                } catch let saveError {
                    persistenceWarning = appState.localizedFormat(
                        "설정을 저장하지 못했습니다: %@",
                        appState.localizedError(saveError)
                    )
                }
                compatibilityDBStatusMessage = DiagnosticWarningText.combined(
                    updateMessage,
                    persistenceWarning
                ) ?? updateMessage
                appState.setNotice(compatibilityDBStatusMessage, kind: .failure)
            }
        }
    }

    private func applyCompatibilityDBUpdateRecords(_ records: [CompatibilityRecipeRecord]) throws {
        _ = try modelContext.applyCompatibilityRecipeSnapshot(records)
    }

    private func compatibilityDBStatusText(for settings: AppSettingsRecord) -> String {
        let kind = settings.lastCompatibilityDBUpdateStatusKind.flatMap(CompatibilityDBUpdateStatusKind.init(rawValue:))
        switch kind {
        case .succeeded:
            return appState.localizedFormat(
                "호환성 DB 업데이트 완료: %d개 추가, %d개 갱신",
                settings.lastCompatibilityDBUpdateImportedCount ?? 0,
                settings.lastCompatibilityDBUpdateUpdatedCount ?? 0
            )
        case .failed:
            return appState.localized("마지막 호환성 DB 업데이트가 실패했습니다.")
        case .notStarted:
            return appState.localized("호환성 DB 업데이트를 아직 실행하지 않았습니다.")
        case nil:
            let legacyStatus = settings.lastCompatibilityDBUpdateStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
            if legacyStatus == nil || legacyStatus?.isEmpty == true ||
                legacyStatus == "호환성 DB 업데이트를 아직 실행하지 않았습니다." {
                return appState.localized("호환성 DB 업데이트를 아직 실행하지 않았습니다.")
            }
            if settings.lastCompatibilityDBUpdateAt != nil {
                return appState.localized("호환성 DB 업데이트를 이전 버전에서 실행했습니다.")
            }
            return appState.localized("이전 버전의 호환성 DB 업데이트 상태를 다시 확인해야 합니다.")
        }
    }

    @discardableResult
    private func saveMaintenanceSettings() -> Bool {
        do {
            let settings = try appState.loadOrCreateSettings(in: modelContext)
            let persistedAutoCleanup = settings.isLogAutoCleanupEnabled ?? true
            let persistedRetentionDays = min(max(settings.logRetentionDays ?? 30, 1), 365)
            let persistedLaunchLogLimit = min(max(settings.launchLogLimit ?? 20, 1), 200)
            settings.isLogAutoCleanupEnabled = appState.isLogAutoCleanupEnabled
            settings.logRetentionDays = appState.logRetentionDays
            settings.launchLogLimit = appState.launchLogLimit
            settings.updatedAt = Date()
            do {
                try modelContext.saveOrRollback()
            } catch {
                appState.isLogAutoCleanupEnabled = persistedAutoCleanup
                appState.logRetentionDays = persistedRetentionDays
                appState.launchLogLimit = persistedLaunchLogLimit
                throw error
            }
            logCleanupStatusMessage = appState.localized("보존 설정을 저장했습니다.")
            return true
        } catch {
            logCleanupStatusMessage = appState.localizedError(error)
            return false
        }
    }

    private func cleanupLogsNow() {
        guard !isCleaningLogs, saveMaintenanceSettings() else { return }
        isCleaningLogs = true
        logCleanupStatusMessage = appState.localized("정리할 문제 분석 기록을 확인하는 중입니다.")
        let retentionDays = appState.logRetentionDays
        let launchLogLimit = appState.launchLogLimit
        Task {
            defer { isCleaningLogs = false }
            do {
                let cleanupTask = try services.logRetentionService.cleanupInBackground(
                    retentionDays: retentionDays,
                    launchLogLimit: launchLogLimit
                )
                let result = try await cleanupTask.value
                logCleanupStatusMessage = appState.localizedFormat(
                    "%d개 기록을 정리했습니다. 확보한 공간: %@",
                    result.removedFiles,
                    appState.localizedByteCount(result.freedBytes)
                )
            } catch {
                logCleanupStatusMessage = appState.localizedError(error)
            }
        }
    }

    private func legalRow(_ text: String) -> some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(palette.success)
                .padding(.top, 2)
            Text(appState.localized(text))
                .font(.callout)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }

    private func openLegalDocument(_ document: LegalDocument) {
        guard let url = document.bundledURL(language: appState.effectiveLanguageMode) else {
            legalDocumentStatusMessage = appState.localizedFormat("법무 문서를 찾을 수 없습니다: %@", document.fileName)
            return
        }
        if appState.openFileURL(url) {
            legalDocumentStatusMessage = appState.localizedFormat("법무 문서를 열었습니다: %@", document.fileName)
        }
    }

    private func clearTaskLater(_ noticeID: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(3))
            appState.clearNotice(id: noticeID)
        }
    }
}

private struct SettingStatusRow: View {
    var title: String
    var value: String
    var status: CheckStatus
    var buttonTitle: String
    var buttonSystemImage: String
    var isDisabled = false
    var disabledReason: String?
    var action: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let horizontalTextColumnMinimumWidth: CGFloat = 320
    private let actionColumnMinimumWidth: CGFloat = 220
    private let actionColumnIdealWidth: CGFloat = 280
    private let actionColumnMaximumWidth: CGFloat = 360

    var body: some View {
        Group {
            if shouldUseStackedLayout {
                rowContent(horizontal: false)
            } else {
                ViewThatFits(in: .horizontal) {
                    rowContent(horizontal: true)
                    rowContent(horizontal: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    private var shouldUseStackedLayout: Bool {
        switch dynamicTypeSize {
        case .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5:
            true
        default:
            false
        }
    }

    private func rowContent(horizontal: Bool) -> some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        return Group {
            if horizontal {
                HStack(alignment: .top, spacing: 12) {
                    textColumn(palette: palette)
                        .frame(minWidth: horizontalTextColumnMinimumWidth, maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(2)
                    Spacer(minLength: 12)
                    actionColumn(palette: palette, trailing: true)
                        .frame(
                            minWidth: actionColumnMinimumWidth,
                            idealWidth: actionColumnIdealWidth,
                            maxWidth: actionColumnMaximumWidth,
                            alignment: .trailing
                        )
                        .layoutPriority(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    textColumn(palette: palette)
                    actionColumn(palette: palette, trailing: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func textColumn(palette: ForgePlayPalette) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(appState.localized(title))
                        .font(.headline)
                        .foregroundStyle(palette.text)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    StatusBadge(label: status.label, status: status)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(appState.localized(title))
                        .font(.headline)
                        .foregroundStyle(palette.text)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    StatusBadge(label: status.label, status: status)
                }
            }
            AdaptiveDetailText(
                text: value,
                font: .caption,
                color: palette.secondaryText
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionColumn(palette: ForgePlayPalette, trailing: Bool) -> some View {
        let horizontalAlignment: HorizontalAlignment = trailing ? .trailing : .leading
        let textAlignment: TextAlignment = trailing ? .trailing : .leading

        return VStack(alignment: horizontalAlignment, spacing: 4) {
            ThemedActionButton(
                title: buttonTitle,
                systemImage: buttonSystemImage,
                prominence: .secondary,
                isDisabled: isDisabled,
                controlSize: .small
            ) {
                action()
            }
            .frame(minWidth: 132, idealWidth: 190, maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)

            if isDisabled, let disabledReason {
                Text(appState.localized(disabledReason))
                    .font(.caption2)
                    .lineLimit(nil)
                    .multilineTextAlignment(textAlignment)
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
