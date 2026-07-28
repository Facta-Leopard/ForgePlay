import AppKit
import SwiftData
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case environment
    case maintenance
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "일반"
        case .environment: "프리픽스 · 동기화"
        case .maintenance: "진단 및 데이터"
        case .about: "정보"
        }
    }
}

struct SettingsView: View {
    var sheetPresenter: ((SheetDestination) -> Void)? = nil
    var opensMainWindowForNavigation = false
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \SteamGameRecord.name) private var games: [SteamGameRecord]
    @Query(sort: \LaunchRecord.startedAt, order: .reverse) private var launchRecords: [LaunchRecord]
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

    private var readiness: SetupReadiness {
        appState.setupReadiness
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
            "설정",
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
                            title: "처음 설정으로 이동",
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
                    Text(appState.localized("서명된 HTTPS index.json만 반영합니다. 서명 검증에 실패하면 기존 호환성 정보를 그대로 사용합니다."))
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
                        legalRow("Apple Foundation Models는 로컬 보조 진단에만 사용하며, 권장 조치는 앱 allowlist와 사용자 확인을 거친 뒤 적용합니다.")
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
            do {
                _ = try await services.refreshSetupWorkflow(
                    appState: appState,
                    in: modelContext,
                    hasSteamReferences: !games.isEmpty,
                    launchRecords: launchRecords
                )
            } catch {
                appState.setError(error)
            }
            loadSettings()
            refreshReadiness()
        }
        .onChange(of: games.count) { _, _ in refreshReadiness() }
        .onChange(of: appState.selectedRootURL?.path) { _, _ in refreshReadiness() }
        .onChange(of: appState.runtimeExecutableURL?.path) { _, _ in refreshReadiness() }
        .onChange(of: services.steamEnvironmentRevision) { _, _ in refreshReadiness() }
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
        guard let url = appState.runtimeExecutableURL else { return .warning }
        guard FileManager.default.fileExists(atPath: url.path) else { return .error }
        let capability: WindowsRuntimeCapability
        do {
            capability = try services.windowsRuntimeService.inspectRuntimeCapability(executable: url)
        } catch {
            return .error
        }
        let verification = SteamClientCompatibilityVerifier.verify(capability: capability)
        if !verification.canLaunchWindowsSteam { return .error }
        return verification.canLaunchManagedSteamGames ? .ok : .warning
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
        guard let url = appState.runtimeExecutableURL else {
            return appState.localized("ForgePlay Runtime을 확인하지 못했습니다.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return appState.localizedFormat("선택했던 파일을 찾을 수 없습니다: %@", url.path)
        }
        do {
            let verification = try services.steamPrefixService.inspectSteamClientCompatibility(url)
            if !verification.canLaunchWindowsSteam {
                return appState.localized(verification.userMessage)
            }
            let productRuntimeName = appState.localized(
                WindowsRuntimeDisplayName.productRuntimeName(for: verification.capability)
            )
            return appState.localizedFormat(
                "%@ · %@",
                productRuntimeName,
                appState.localized(WindowsRuntimeDisplayName.statusSummary(for: verification.capability))
            )
        } catch {
            return appState.localizedError(error)
        }
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
        services.synchronizeSetupWorkflow(
            appState: appState,
            hasSteamReferences: !games.isEmpty,
            launchRecords: launchRecords
        )
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
                _ = try await services.refreshSetupWorkflow(
                    appState: appState,
                    in: modelContext,
                    hasSteamReferences: !games.isEmpty,
                    launchRecords: launchRecords
                )
            } catch {
                appState.setError(error)
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
