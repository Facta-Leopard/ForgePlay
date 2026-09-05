import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \SteamGameRecord.name) private var games: [SteamGameRecord]
    @Query(sort: \DiagnosticRecord.createdAt, order: .reverse) private var diagnostics: [DiagnosticRecord]
    @Query private var launchRecords: [LaunchRecord]

    init() {
        var diagnosticDescriptor = FetchDescriptor<DiagnosticRecord>(
            sortBy: [SortDescriptor(\DiagnosticRecord.createdAt, order: .reverse)]
        )
        diagnosticDescriptor.fetchLimit = 1
        _diagnostics = Query(diagnosticDescriptor)
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

    private var runtimeSystemCheck: SystemCheckResult? {
        appState.latestChecks.first { $0.category == .windowsRuntime }
    }

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    var body: some View {
        ForgePageScaffold(
            "대시보드",
            subtitle: "현재 준비 상태를 확인하고 다음 작업을 바로 진행합니다.",
            systemImage: "square.grid.2x2"
        ) {
            dashboardHeaderActions
        } content: {
            dashboardNextActionPanel
            readinessSummarySection

            ForgeSection(
                "최근 활동",
                subtitle: "Steam 실행 상태와 가장 최근 문제 분석 결과입니다.",
                systemImage: "clock.arrow.circlepath"
            ) {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 420), spacing: ForgePlayLayout.sectionSpacing)
                ], spacing: ForgePlayLayout.sectionSpacing) {
                    steamEntryCard
                    recentDiagnosticsCard
                }
            }

            ForgeSection(
                "상세 상태",
                subtitle: "실행 구성과 Mac 점검 결과가 필요할 때 확인합니다.",
                systemImage: "list.bullet.rectangle"
            ) {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 420), spacing: ForgePlayLayout.sectionSpacing)
                ], spacing: ForgePlayLayout.sectionSpacing) {
                    runConfigurationCard
                    quickCheckCard
                }
            }
        }
    }

    private var refreshStatusButton: some View {
        ThemedActionButton(
            title: services.setupWorkflowCoordinator.isSystemCheckInProgress
                ? "확인 중"
                : "상태 새로고침",
            systemImage: "arrow.clockwise",
            prominence: .secondary,
            isDisabled: services.setupWorkflowCoordinator.isSystemCheckInProgress,
            controlSize: .small
        ) {
            Task {
                await refreshSystemStatus()
            }
        }
        .frame(minWidth: 132, idealWidth: 156, maxWidth: 190)
    }

    private var dashboardHeaderActions: some View {
        ResponsiveActionRow(alignment: .trailing, spacing: 8) {
            SectionHelpButton(section: .dashboard)
            refreshStatusButton
        }
    }

    private var dashboardNextActionPanel: some View {
        ForgeWorkflowActionPanel(
            eyebrow: canLaunchSteamFromDashboard ? "실행 준비 완료" : "다음 작업",
            title: canLaunchSteamFromDashboard ? "Windows용 Steam 실행" : appState.setupStage.title,
            detail: canLaunchSteamFromDashboard
                ? "Windows용 Steam을 열고 Steam 라이브러리에서 게임을 실행합니다."
                : appState.setupStage.beginnerDescription,
            status: canLaunchSteamFromDashboard ? .ok : dashboardPrimaryStatus,
            systemImage: canLaunchSteamFromDashboard ? "play.fill" : appState.setupStage.symbolName
        ) {
            ResponsiveActionRow(alignment: .trailing, spacing: 8) {
                if canLaunchSteamFromDashboard {
                    PrimaryActionButton(title: "백엔드 선택 후 실행", systemImage: "slider.horizontal.3") {
                        appState.selectedSection = .steamLaunch
                    }
                    SecondaryActionButton(title: "문제 진단 (베타)", systemImage: "waveform.path.ecg.rectangle") {
                        appState.selectedSection = .diagnostics
                    }
                } else {
                    PrimaryActionButton(title: "설정 계속", systemImage: "arrow.right") {
                        appState.selectedSection = .setup
                    }
                    SecondaryActionButton(title: "문제 진단 (베타)", systemImage: "waveform.path.ecg.rectangle") {
                        appState.selectedSection = .diagnostics
                    }
                }
            }
        }
    }

    private var dashboardPrimaryStatus: CheckStatus {
        if readiness.rootIssue != nil || readiness.steamPrefixIssue != nil {
            return .error
        }
        return .warning
    }

    private var readinessSummarySection: some View {
        ForgeSection(
            "준비 상태",
            subtitle: "Steam 실행에 필요한 핵심 항목만 요약합니다.",
            systemImage: "checkmark.shield"
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 210), spacing: 10)],
                spacing: 10
            ) {
                ForgeStatusSummaryItem(
                    title: "Mac 상태",
                    value: macReadinessSummary,
                    status: appState.systemCheckSummary.displayStatus,
                    systemImage: "desktopcomputer"
                )
                ForgeStatusSummaryItem(
                    title: PairedTerm.gameEngine.displayName,
                    value: shortStatusValue(for: gameEngineDisplayStatus),
                    status: gameEngineDisplayStatus,
                    systemImage: "gearshape.2"
                )
                ForgeStatusSummaryItem(
                    title: PairedTerm.executionEnvironment.displayName,
                    value: readiness.hasSteamPrefix ? appState.localized("준비됨") : appState.localized("준비 필요"),
                    status: executionEnvironmentDisplayStatus,
                    systemImage: "externaldrive"
                )
                ForgeStatusSummaryItem(
                    title: "Windows용 Steam",
                    value: readiness.hasSteamExecutable ? appState.localized("설치됨") : appState.localized("설치 필요"),
                    status: steamDisplayStatus,
                    systemImage: "play.circle"
                )
            }
        }
    }

    private var macReadinessSummary: String {
        switch appState.systemCheckSummary.phase {
        case .unverified: appState.localized("확인 필요")
        case .blocked: appState.localized("문제 있음")
        case .readyWithWarnings: appState.localized("준비됨 · 확인 필요")
        case .ready: appState.localized("준비됨")
        }
    }

    private func shortStatusValue(for status: CheckStatus) -> String {
        switch status {
        case .ok: appState.localized("준비됨")
        case .warning: appState.localized("확인 필요")
        case .error: appState.localized("문제 있음")
        case .unknown: appState.localized("미확인")
        }
    }

    private var steamEntryCard: some View {
        ForgeCard("최근 Steam 상태", systemImage: "play.circle") {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        StatusBadge(label: steamEntryStatusLabel, status: steamEntryStatus)
                        Text(appState.localizedFormat("%d개 Steam 참고 기록", games.count))
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        StatusBadge(label: steamEntryStatusLabel, status: steamEntryStatus)
                        Text(appState.localizedFormat("%d개 Steam 참고 기록", games.count))
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                Text(appState.localized("Windows용 Steam을 열고 Steam 라이브러리에서 게임을 실행합니다."))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                SteamLaunchRecordStatusPanel(
                    record: latestSteamLaunchRecord
                )
                ThemedActionButton(
                    title: "Steam 실행 화면",
                    systemImage: "arrow.right",
                    prominence: .secondary,
                    controlSize: .small
                ) {
                    appState.selectedSection = .steamLaunch
                }
                .frame(minWidth: 150, idealWidth: 180, maxWidth: 230)
            }
        }
    }

    private var runConfigurationCard: some View {
        ForgeCard("실행 구성", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 12) {
                configRow(
                    title: PairedTerm.gameEngine.displayName,
                    value: gameEngineDisplayValue,
                    status: gameEngineDisplayStatus
                )
                configRow(
                    title: PairedTerm.executionEnvironment.displayName,
                    value: executionEnvironmentDisplayValue,
                    status: executionEnvironmentDisplayStatus
                )
                configRow(
                    title: "Windows용 Steam",
                    value: steamDisplayValue,
                    status: steamDisplayStatus
                )
                configRow(
                    title: "게임 렌더러 payload",
                    value: steamRendererPolicyDisplayValue,
                    status: steamRendererPolicyDisplayStatus
                )
                ResponsiveActionRow {
                    SecondaryActionButton(title: "설정 열기", systemImage: "wand.and.sparkles") {
                        appState.selectedSection = .setup
                    }
                    ThemedActionButton(
                        title: "실행 설정",
                        systemImage: "slider.horizontal.3",
                        prominence: .secondary
                    ) {
                        appState.selectedSection = .steamLaunch
                    }
                }
            }
        }
    }

    private var quickCheckCard: some View {
        ForgeCard("실행 전 점검", systemImage: "checklist") {
            VStack(alignment: .leading, spacing: 10) {
                if appState.latestChecks.isEmpty {
                    Text(appState.localized("아직 점검 결과가 없습니다. 설정에서 저장 위치를 고른 뒤 상태 새로고침을 누르세요."))
                        .font(.callout)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    ThemedActionButton(
                        title: services.setupWorkflowCoordinator.isSystemCheckInProgress
                            ? "확인 중"
                            : "Mac 상태 확인",
                        systemImage: "checkmark.shield",
                        prominence: .secondary,
                        isDisabled: services.setupWorkflowCoordinator.isSystemCheckInProgress,
                        controlSize: .small
                    ) {
                        Task {
                            await refreshSystemStatus()
                        }
                    }
                    .frame(minWidth: 140, idealWidth: 164, maxWidth: 210)
                } else {
                    ForEach(appState.latestChecks.prefix(5)) { check in
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top) {
                                StatusBadge(label: check.title, status: check.status)
                                Text(appState.localized(check.detail))
                                    .font(.caption)
                                    .foregroundStyle(palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                StatusBadge(label: check.title, status: check.status)
                                Text(appState.localized(check.detail))
                                    .font(.caption)
                                    .foregroundStyle(palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private var recentDiagnosticsCard: some View {
        ForgeCard("최근 문제 분석 기록(Log)", systemImage: "doc.text.magnifyingglass") {
            if let latest = diagnostics.first {
                recentDiagnosticContent(latest)
            } else {
                Text(appState.localized("아직 저장된 진단 결과가 없습니다. Steam 실행 또는 Steam 안에서 시작한 게임이 실패하면 로컬 자동 문제 분석(Rule Engine)이 먼저 실행됩니다."))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func recentDiagnosticContent(_ record: DiagnosticRecord) -> some View {
        switch diagnosticDecodeResult(record) {
        case .success(let result):
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top) {
                        Text(appState.localized(result.category.beginnerTitle))
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        RiskBadge(risk: result.riskLevel)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(appState.localized(result.category.beginnerTitle))
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        RiskBadge(risk: result.riskLevel)
                    }
                }
                Text(result.localizedUserMessage(appState: appState))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                ThemedActionButton(
                    title: "문제 진단 (베타) 보기",
                    systemImage: "stethoscope",
                    prominence: .secondary,
                    controlSize: .small
                ) {
                    appState.selectedSection = .diagnostics
                }
                .frame(minWidth: 140, idealWidth: 164, maxWidth: 210)
            }
        case .failure(let error):
            VStack(alignment: .leading, spacing: 8) {
                Text(appState.localized("저장된 진단 기록 오류"))
                    .font(.headline)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text(appState.localizedError(error))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                ThemedActionButton(
                    title: "문제 진단 (베타) 보기",
                    systemImage: "stethoscope",
                    prominence: .secondary,
                    controlSize: .small
                ) {
                    appState.selectedSection = .diagnostics
                }
                .frame(minWidth: 140, idealWidth: 164, maxWidth: 210)
            }
        }
    }

    private func diagnosticDecodeResult(_ record: DiagnosticRecord) -> Result<DiagnosticResult, Error> {
        Result { try record.requiredDecodedResult() }
    }

    private func configRow(title: String, value: String, status: CheckStatus) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                StatusBadge(label: title, status: status)
                AdaptiveValueText(
                    text: value,
                    font: .callout,
                    color: palette.text,
                    isTextSelectionEnabled: false
                )
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                StatusBadge(label: title, status: status)
                AdaptiveValueText(
                    text: value,
                    font: .callout,
                    color: palette.text,
                    isTextSelectionEnabled: false
                )
            }
        }
    }

    private var steamDisplayValue: String {
        if let bundledRuntimeUnavailableReason { return bundledRuntimeUnavailableReason }
        if let issue = readiness.rootIssue { return appState.localizedError(issue) }
        if readiness.hasSteamExecutable { return appState.localized("설치됨") }
        return appState.localized("설치 필요")
    }

    private var steamDisplayStatus: CheckStatus {
        if !canRunBundledWindowsRuntime { return .warning }
        if readiness.rootIssue != nil { return .error }
        if readiness.steamPrefixIssue != nil { return .error }
        return readiness.hasSteamExecutable ? .ok : .warning
    }

    private var executionEnvironmentDisplayValue: String {
        if let bundledRuntimeUnavailableReason { return bundledRuntimeUnavailableReason }
        if let issue = readiness.rootIssue { return appState.localizedError(issue) }
        return readiness.hasSteamPrefix ? appState.localized("Steam 프리픽스") : appState.localized("Steam 프리픽스 필요")
    }

    private var executionEnvironmentDisplayStatus: CheckStatus {
        if !canRunBundledWindowsRuntime { return .warning }
        if readiness.rootIssue != nil { return .error }
        return readiness.hasSteamPrefix ? .ok : .warning
    }

    private var gameEngineDisplayValue: String {
        if let bundledRuntimeUnavailableReason {
            return bundledRuntimeUnavailableReason
        }
        guard appState.runtimeExecutableURL != nil else {
            return appState.localized("선택 필요")
        }
        guard let runtimeSystemCheck else {
            return appState.localized("확인 중")
        }
        return appState.localized(runtimeSystemCheck.detail)
    }

    private var gameEngineDisplayStatus: CheckStatus {
        if !canRunBundledWindowsRuntime { return .warning }
        guard appState.runtimeExecutableURL != nil else { return .warning }
        return runtimeSystemCheck?.status ?? .unknown
    }

    private var steamRendererPolicyDisplayValue: String {
        if let rendererInspection = readiness.rendererInspection {
            return appState.localized(rendererInspection.userMessage)
        }
        guard appState.runtimeExecutableURL != nil else {
            return appState.localized("ForgePlay Runtime을 먼저 확인하세요.")
        }
        if let runtimeSystemCheck, runtimeSystemCheck.status == .error {
            return appState.localized(runtimeSystemCheck.detail)
        }
        return appState.localized("확인 중")
    }

    private var steamRendererPolicyDisplayStatus: CheckStatus {
        if let rendererInspection = readiness.rendererInspection {
            return rendererInspection.status
        }
        guard appState.runtimeExecutableURL != nil else { return .warning }
        if let runtimeSystemCheck, runtimeSystemCheck.status == .error { return .error }
        return .unknown
    }

    private var canRunBundledWindowsRuntime: Bool {
        ForgePlayRuntimeCapabilityPolicy.canRunBundledWindowsRuntime
    }

    private var steamEntryStatusLabel: String {
        if dashboardSteamLaunchBlocker != nil { return appState.localized("Steam 실행 차단") }
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

    private var steamEntryStatus: CheckStatus {
        if dashboardSteamLaunchBlocker != nil { return .warning }
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

    private var canLaunchSteamFromDashboard: Bool {
        !appState.isSteamLaunchInProgress &&
            appState.steamStorageOperationMountID == nil &&
            !services.steamPrefixLifecycleCoordinator.isBusy &&
            dashboardSteamLaunchBlocker == nil
    }

    private func steamSurfaceStatusLabel(for record: LaunchRecord) -> String {
        switch record.steamUISurface {
        case .some(.signIn): "Steam 로그인 화면 확인됨"
        case .some(.steamGuard): "Steam Guard 화면 확인됨"
        case .some(.library): "Steam 라이브러리 확인됨"
        case .some(.unknown), .none: "Steam 화면 확인됨"
        }
    }

    private var dashboardSteamLaunchBlocker: String? {
        if let bundledRuntimeUnavailableReason {
            return bundledRuntimeUnavailableReason
        }
        if let issue = readiness.rootIssue {
            return appState.localizedError(issue)
        }
        guard appState.runtimeExecutableURL != nil else {
            return appState.localized("ForgePlay Runtime을 먼저 확인하세요.")
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

    private var bundledRuntimeUnavailableReason: String? {
        canRunBundledWindowsRuntime
            ? nil
            : appState.localized(ForgePlayRuntimeCapabilityPolicy.unavailableReasonKey)
    }

    private func refreshSystemStatus() async {
        let progressNotice = appState.setTask(appState.localized("Mac 상태를 확인하는 중입니다."))
        defer {
            if let progressNotice {
                appState.clearNotice(id: progressNotice.id)
            }
        }
        while true {
            do {
                try Task.checkCancellation()
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
                    return
                }
                await Task.yield()
            } catch is CancellationError {
                return
            } catch {
                appState.setError(error)
                return
            }
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

}
