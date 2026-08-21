import AppKit
import SwiftData
import SwiftUI

struct SheetHostView: View {
    let destination: SheetDestination
    var sheetPresenter: ((SheetDestination) -> Void)? = nil
    var opensMainWindowForNavigation = false
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query private var games: [SteamGameRecord]

    init(
        destination: SheetDestination,
        sheetPresenter: ((SheetDestination) -> Void)? = nil,
        opensMainWindowForNavigation: Bool = false
    ) {
        self.destination = destination
        self.sheetPresenter = sheetPresenter
        self.opensMainWindowForNavigation = opensMainWindowForNavigation
        var gameDescriptor = FetchDescriptor<SteamGameRecord>()
        gameDescriptor.fetchLimit = 1
        _games = Query(gameDescriptor)
    }

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        ForgeSheetChrome(onClose: { dismiss() }) {
            Group {
                switch destination {
                case .chooseRoot:
                    ManagedStorageLocationView()
                case .importAppleSupplementalRenderer:
                    AppleSupplementalRendererImportView(
                        bundledRuntimePath: appState.runtimeExecutableURL?.path,
                        importSupplementalRenderer: importAppleSupplementalRenderer
                    )
                case .chooseSteamInstaller:
                    GuidedSelectionView(
                        title: "Windows용 Steam 설치",
                        subtitle: "Steam 공식 페이지에서 SteamSetup.exe를 받은 뒤 선택하면 ForgePlay가 Steam 프리픽스 안에 자동으로 설치하고 결과를 확인합니다.",
                        primaryTitle: "Steam 공식 페이지 열기",
                        primaryIcon: "safari",
                        secondaryTitle: "SteamSetup.exe 선택 후 설치",
                        secondaryIcon: "square.and.arrow.down",
                        message: appState.steamInstallerURL?.path ?? "Steam 로그인은 Steam 창 안에서 직접 진행합니다. ForgePlay는 비밀번호를 묻거나 저장하지 않습니다.",
                        secondaryDisabled: !ForgePlayRuntimeCapabilityPolicy.canRunBundledWindowsRuntime,
                        secondaryDisabledReason: ForgePlayRuntimeCapabilityPolicy.canRunBundledWindowsRuntime
                            ? nil
                            : ForgePlayRuntimeCapabilityPolicy.unavailableReasonKey,
                        primaryAction: { appState.openExternalURL(SteamManager.officialDownloadURL) },
                        secondaryAction: chooseSteamInstallerAndInstall
                    )
                case .chooseRuntimeInstallerCatalog:
                    RuntimeInstallerCatalogSheet(sheetPresenter: presentSheet)
                case .chooseRuntimeInstaller(let runtime):
                    RuntimeInstallerSheet(runtime: runtime, sheetPresenter: presentSheet)
                case .diagnosticGuide(let payload):
                    DiagnosticGuidanceSheet(
                        payload: payload,
                        sheetPresenter: presentSheet,
                        opensMainWindowForNavigation: opensMainWindowForNavigation
                    )
                case .supportBundle(let url):
                    GuidedSelectionView(
                        title: "지원 번들 생성됨",
                        subtitle: "일부 진단 자료가 수집되지 않았을 수 있습니다. 번들 안 README.md와 metadata/bundle-manifest.json의 collectionStatus를 확인하고, 전송 전 가려진 경로와 토큰을 직접 검토하세요.",
                        primaryTitle: "Finder에서 보기",
                        primaryIcon: "folder",
                        secondaryTitle: nil,
                        secondaryIcon: nil,
                        message: url.path,
                        primaryAction: { appState.revealInFinder(url) },
                        secondaryAction: nil
                    )
                case .usageGuide:
                    UsageGuideView()
                case .sectionHelp(let section):
                    ContextualHelpView(
                        section: section,
                        sheetPresenter: presentSheet
                    )
                }
            }
        }
        .preferredColorScheme(appState.themeMode.preferredColorScheme)
        .tint(palette.primary)
        .foregroundStyle(palette.text)
        .background(palette.background.ignoresSafeArea())
    }

    private func presentSheet(_ destination: SheetDestination) {
        if let sheetPresenter {
            sheetPresenter(destination)
        } else {
            appState.presentedSheet = destination
        }
    }

    private func importAppleSupplementalRenderer() {
        guard let url = OpenPanelPresenter.chooseFileOrDirectory(
            title: appState.localized("Apple D3DMetal 보조 렌더러 가져오기"),
            message: appState.localized("Apple 공식 Evaluation environment for Windows games DMG 또는 redist 폴더를 선택하세요. ForgePlay는 D3DMetal 보조 렌더러만 앱 데이터 영역으로 가져오며, 실행에는 앱에 포함된 ForgePlay Runtime을 계속 사용합니다."),
            prompt: appState.localized("선택")
        ) else { return }
        let progressNotice = appState.setTask(appState.localized("선택한 Apple D3DMetal 보조 렌더러를 확인하는 중입니다. DMG는 읽기 전용으로 자동 마운트합니다."))
        Task {
            do {
                let result = try await services
                    .importAppleSupplementalRenderer(at: url)
                try await refreshSetupWorkflowUntilCommitted()
                if let progressNotice {
                    appState.clearNotice(id: progressNotice.id)
                }
                appState.setNotice(
                    appState.localized(result.message),
                    kind: .success
                )
                dismiss()
            } catch {
                appState.setError(error)
                if let progressNotice {
                    appState.clearNotice(id: progressNotice.id)
                }
            }
        }
    }

    private func chooseSteamInstallerAndInstall() {
        guard let installer = OpenPanelPresenter.chooseFile(
            title: appState.localized("SteamSetup.exe 선택"),
            message: appState.localized("Steam 공식 페이지에서 받은 Windows용 설치 파일인 SteamSetup.exe를 선택하세요."),
            prompt: appState.localized("선택 후 설치"),
            allowedExtensions: ["exe"]
        ) else { return }
        guard services.validateSteamInstaller(installer) else {
            appState.setNotice(appState.localized("SteamSetup.exe 파일을 선택해야 합니다."), kind: .warning)
            return
        }
        guard let runtimeExecutable = appState.runtimeExecutableURL else {
            appState.setNotice(appState.localized("ForgePlay Runtime을 먼저 확인하세요."), kind: .warning)
            return
        }
        let readiness: SetupReadiness
        do {
            readiness = try services.synchronizeSetupWorkflow(
                appState: appState,
                in: modelContext,
                hasSteamReferences: !games.isEmpty
            )
        } catch {
            appState.setError(error)
            return
        }
        if let issue = readiness.rootIssue {
            appState.setNotice(appState.localizedError(issue), kind: .failure)
            return
        }
        guard readiness.hasSteamPrefix else {
            appState.setNotice(appState.localized("Steam 프리픽스를 먼저 만들어야 합니다."), kind: .warning)
            return
        }
        appState.setPersistedFileSelection(installer, for: .steamInstaller)
        let installerPersistenceWarning = appState.saveWarning(to: modelContext)
        let steamLanguage = appState.effectiveSteamClientLanguage
        appState.setTask(appState.localized("Steam 설치 프로그램을 실행하는 중입니다."))
        Task {
            do {
                let preparation = try await services.prepareSteamPrefix(
                    runtimeExecutable: runtimeExecutable,
                    synchronizationSelection: appState.wineSynchronizationSelection
                )
                let prefixPersistenceWarning = savePrefixRecordWarning(metadata: preparation.metadata)
                let prefixPreparationWarning = DiagnosticWarningText.combined(
                    prefixPersistenceWarning,
                    preparation.localizedPreviousEnvironmentCleanupWarning(appState: appState)
                )
                let installResult = try await services.installSteamInSteamPrefix(
                    runtimeExecutable: runtimeExecutable,
                    installer: installer,
                    language: steamLanguage,
                    videoMemorySelection: appState.steamVideoMemorySelection,
                    synchronizationSelection: appState.wineSynchronizationSelection
                )
                let result = installResult.processResult
                try await refreshSetupWorkflowUntilCommitted()
                if result.succeeded {
                    switch installResult.verificationState {
                    case .verified, .steamClientServiceNotReady:
                        let message = DiagnosticWarningText.combined(
                            appState.localized("Steam 설치가 끝났습니다."),
                            installerPersistenceWarning,
                            prefixPreparationWarning,
                            installResult.compatibilityPreparationWarning.map {
                                appState.localizedFormat("Steam 실행 경로 자동 준비는 완료하지 못했습니다. 첫 Steam 실행에서 다시 시도합니다: %@", $0)
                            }
                        ) ?? appState.localized("Steam 설치가 끝났습니다.")
                        let notice = appState.setNotice(
                            message,
                            kind: installResult.verificationState == .verified &&
                                installerPersistenceWarning == nil &&
                                prefixPreparationWarning == nil &&
                                installResult.compatibilityPreparationWarning == nil ? .success : .warning
                        )
                        clearTaskLater(notice.id)
                    case .steamLanguageNotReady:
                        appState.setNotice(
                            DiagnosticWarningText.combined(
                                appState.localized("Steam 자체 언어 설정을 첫 화면 전에 검증하지 못해 설치 완료로 처리하지 않았습니다."),
                                installerPersistenceWarning,
                                prefixPreparationWarning,
                                installResult.compatibilityPreparationWarning.map {
                                    appState.localizedFormat("Steam 실행 경로 자동 준비는 완료하지 못했습니다. 첫 Steam 실행에서 다시 시도합니다: %@", $0)
                                }
                            ) ?? appState.localized("Steam 자체 언어 설정을 첫 화면 전에 검증하지 못해 설치 완료로 처리하지 않았습니다."),
                            kind: .failure,
                            logURL: result.stderrLog,
                            diagnosticProcessResult: result
                        )
                    case .steamExecutableNotCreatedOrChanged:
                        appState.setNotice(
                            DiagnosticWarningText.combined(
                                appState.localized("Steam 설치 프로세스는 종료됐지만 이번 실행에서 안전한 steam.exe 생성 또는 변경을 확인하지 못했습니다. 설치 로그를 확인하세요."),
                                installerPersistenceWarning,
                                prefixPreparationWarning
                            ) ?? appState.localized("Steam 설치 프로세스는 종료됐지만 이번 실행에서 안전한 steam.exe 생성 또는 변경을 확인하지 못했습니다. 설치 로그를 확인하세요."),
                            kind: .warning
                        )
                    case .installerFailed:
                        // `result.succeeded` and the model state are derived
                        // from the same process result. Keep an explicit
                        // fallback if that contract is ever changed.
                        presentGuidance(
                            title: appState.localized("Steam 설치"),
                            result: result,
                            fallbackReason: appState.localized("Steam 설치 프로그램 실행이 실패했습니다. SteamSetup.exe가 공식 설치 파일인지 확인하고, ForgePlay Runtime과 Steam 프리픽스 상태를 다시 점검하세요."),
                            prefixPersistenceWarning: DiagnosticWarningText.combined(
                                installerPersistenceWarning,
                                prefixPreparationWarning
                            )
                        )
                    }
                } else if result.didTimeOut {
                    presentGuidance(
                        title: appState.localized("Steam 설치"),
                        result: result,
                        fallbackReason: appState.localized("Steam 설치 프로그램 실행 시간이 초과되었습니다. Windows 설치 창이 열려 있는지 확인하고, 로그의 마지막 오류를 확인하세요."),
                        prefixPersistenceWarning: DiagnosticWarningText.combined(
                            installerPersistenceWarning,
                            prefixPreparationWarning
                        )
                    )
                    let warning = DiagnosticWarningText.combined(
                        installerPersistenceWarning,
                        prefixPreparationWarning
                    )
                    appState.setNotice(
                        DiagnosticWarningText.combined(
                            appState.localizedFormat("Steam 설치 시간이 너무 오래 걸려 중단했습니다. 로그를 확인하세요: %@", result.stderrLog.path),
                            warning
                        ) ?? appState.localizedFormat("Steam 설치 시간이 너무 오래 걸려 중단했습니다. 로그를 확인하세요: %@", result.stderrLog.path),
                        kind: .failure,
                        logURL: result.stderrLog,
                        diagnosticProcessResult: result
                    )
                } else {
                    presentGuidance(
                        title: appState.localized("Steam 설치"),
                        result: result,
                        fallbackReason: appState.localized("Steam 설치 프로그램 실행이 실패했습니다. SteamSetup.exe가 공식 설치 파일인지 확인하고, ForgePlay Runtime과 Steam 프리픽스 상태를 다시 점검하세요."),
                        prefixPersistenceWarning: DiagnosticWarningText.combined(
                            installerPersistenceWarning,
                            prefixPreparationWarning
                        )
                    )
                    let warning = DiagnosticWarningText.combined(
                        installerPersistenceWarning,
                        prefixPreparationWarning
                    )
                    appState.setNotice(
                        DiagnosticWarningText.combined(
                            appState.localizedFormat("Steam 설치에 실패했습니다. 로그를 확인하세요: %@", result.stderrLog.path),
                            warning
                        ) ?? appState.localizedFormat("Steam 설치에 실패했습니다. 로그를 확인하세요: %@", result.stderrLog.path),
                        kind: .failure,
                        logURL: result.stderrLog,
                        diagnosticProcessResult: result
                    )
                }
            } catch {
                if let result = processRunResult(from: error) {
                    presentGuidance(
                        title: appState.localized("Steam 설치"),
                        result: result,
                        fallbackReason: appState.localized("Steam 설치 준비 단계에서 실패했습니다. ForgePlay Runtime과 Steam 프리픽스를 다시 확인하세요."),
                        prefixPersistenceWarning: installerPersistenceWarning
                    )
                }
                appState.setError(error)
            }
        }
        dismiss()
    }

    private func presentGuidance(
        title: String,
        result: ProcessRunResult,
        fallbackReason: String,
        prefixPersistenceWarning: String? = nil
    ) {
        let logSnapshot = LogTextReader.diagnosticSnapshot(from: [result.stdoutLog, result.stderrLog])
        let diagnostics = DiagnosticGuidanceBuilder.diagnostics(
            ruleEngine: services.ruleEngine,
            logText: logSnapshot.text,
            context: .setupOrInstaller,
            language: appState.effectiveLanguageMode,
            fallbackReason: fallbackReason
        )
        let persistenceWarning = saveDiagnosticRecords(diagnostics)
        guard let destination = appState.diagnosticGuideDestination(
            title: title,
            diagnostics: diagnostics,
            logURL: result.stderrLog,
            persistenceWarning: DiagnosticWarningText.combined(
                logSnapshot.readError.map { appState.localizedError($0) },
                prefixPersistenceWarning,
                persistenceWarning
            )
        ) else { return }
        presentSheet(destination)
    }

    private func processRunResult(from error: Error) -> ProcessRunResult? {
        diagnosticProcessRunResult(from: error)
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

    private func saveDiagnosticRecords(_ diagnostics: [DiagnosticResult]) -> String? {
        do {
            try modelContext.saveDiagnosticRecords(diagnostics)
            return nil
        } catch {
            return appState.localizedFormat("진단 결과를 저장하지 못했습니다: %@", forgePlayTechnicalErrorSummary(error))
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

    private func clearTaskLater(_ noticeID: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(3))
            appState.clearNotice(id: noticeID)
        }
    }
}

private struct DiagnosticGuidanceSheet: View {
    var payload: DiagnosticGuidancePayload
    var sheetPresenter: ((SheetDestination) -> Void)? = nil
    var opensMainWindowForNavigation = false
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var runtimeUpdateMessage: String?

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    private var canRunBundledWindowsRuntime: Bool {
        ForgePlayRuntimeCapabilityPolicy.canRunBundledWindowsRuntime
    }

    private var bundledRuntimeUnavailableReason: String {
        appState.localized(ForgePlayRuntimeCapabilityPolicy.unavailableReasonKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let persistenceWarning = payload.persistenceWarning {
                        persistenceWarningBanner(persistenceWarning)
                    }
                    ForEach(payload.diagnostics.prefix(3)) { diagnostic in
                        diagnosticCard(diagnostic)
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 460)

            if let runtimeUpdateMessage {
                Text(runtimeUpdateMessage)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(palette.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            footer
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 760, maxWidth: 760)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.title2)
                .foregroundStyle(palette.warning)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        headerTitle
                        if let primaryDiagnostic = payload.primaryDiagnostic {
                            RiskBadge(risk: primaryDiagnostic.riskLevel)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        headerTitle
                        if let primaryDiagnostic = payload.primaryDiagnostic {
                            RiskBadge(risk: primaryDiagnostic.riskLevel)
                        }
                    }
                }
                Text(appState.localizedFormat("%@ 실행 중 감지한 의존성/호환성 문제입니다.", payload.title))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(appState.localized("로컬 자동 문제 분석 결과입니다. 아래 조치를 먼저 확인하세요."))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var headerTitle: some View {
        Text(appState.localized("실행 문제 해결 안내"))
            .font(.title2.weight(.bold))
            .foregroundStyle(palette.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func persistenceWarningBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(palette.warning)
                .padding(.top, 1)
            Text(message)
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.warning.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.warning.opacity(0.28), lineWidth: 1)
        )
    }

    private func diagnosticCard(_ diagnostic: DiagnosticResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    diagnosticCardHeader(diagnostic)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    diagnosticCardHeader(diagnostic)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(appState.localized(diagnostic.category.beginnerTitle))
                    .font(.headline)
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(diagnostic.localizedUserMessage(appState: appState))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !diagnostic.recommendedActions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(appState.localized("권장 조치"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                    ForEach(diagnostic.recommendedActions) { action in
                        actionRow(action)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private func diagnosticCardHeader(_ diagnostic: DiagnosticResult) -> some View {
        Group {
            Text(appState.localized("감지된 문제"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.secondaryText)
            RiskBadge(risk: diagnostic.riskLevel)
            Text(appState.localizedFormat("%d%% 신뢰도", Int(diagnostic.confidence * 100)))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionRow(_ action: RecommendedAction) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                actionIcon(action)
                diagnosticActionText(action)
                Spacer(minLength: 12)
                actionButton(action)
                    .frame(minWidth: 150, idealWidth: 170, maxWidth: 190)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    actionIcon(action)
                    diagnosticActionText(action)
                }
                actionButton(action)
                    .frame(maxWidth: 220)
                    .padding(.leading, 34)
            }
        }
        .padding(10)
        .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func actionIcon(_ action: RecommendedAction) -> some View {
        Image(systemName: symbolName(for: action))
            .font(.callout.weight(.semibold))
            .foregroundStyle(action.riskLevel.color(in: palette))
            .frame(width: 24, alignment: .center)
            .padding(.top, 3)
    }

    private func diagnosticActionText(_ action: RecommendedAction) -> some View {
        let steps = action.localizedRemediationSteps(
            appState: appState,
            runtimeDefinition: runtimeDefinition(for: action)
        )

        return VStack(alignment: .leading, spacing: 4) {
            Text(appState.localized(action.type.beginnerLabel))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(action.localizedReason(appState: appState))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            RemediationStepsView(steps: steps)
                .padding(.top, 2)
        }
    }

    private func runtimeDefinition(for action: RecommendedAction) -> RuntimeDefinition? {
        guard action.type == .installRuntime, let runtime = action.runtime else { return nil }
        return services.runtimeManager.definition(for: runtime)
    }

    @ViewBuilder
    private func actionButton(_ action: RecommendedAction) -> some View {
        switch action.type {
        case .installRuntime:
            if let runtime = action.runtime {
                ThemedActionButton(
                    title: "설치 안내",
                    systemImage: "square.and.arrow.down",
                    prominence: .secondary,
                    isDisabled: !canRunBundledWindowsRuntime,
                    controlSize: .small
                ) {
                    presentSheet(.chooseRuntimeInstaller(runtime))
                }
            } else {
                EmptyView()
            }
        case .askUserToUpdateRuntime:
            ThemedActionButton(
                title: "ForgePlay Runtime 업데이트 안내",
                systemImage: "arrow.down.app",
                prominence: .primary,
                controlSize: .small,
                action: showRuntimeUpdateGuidance
            )
        case .importAppleSupplementalRenderer:
            ThemedActionButton(
                title: "Apple D3DMetal 보조 렌더러 가져오기",
                systemImage: "shippingbox",
                prominence: .secondary,
                isDisabled: !canRunBundledWindowsRuntime,
                controlSize: .small
            ) {
                presentSheet(.importAppleSupplementalRenderer)
            }
        case .askUserToUpdateMacOS:
            ThemedActionButton(
                title: "macOS 업데이트",
                systemImage: "gearshape.arrow.triangle.2.circlepath",
                prominence: .secondary,
                controlSize: .small
            ) {
                appState.openExternalURL(ExternalLinkPolicy.macOSSoftwareUpdateSettingsURL)
            }
        case .noAction:
            EmptyView()
        case .setWindowsVersion, .setDLLOverride, .addLaunchOption, .markUnsupported:
            ThemedActionButton(
                title: "문제 진단 (베타) 열기",
                systemImage: "stethoscope",
                prominence: .secondary,
                controlSize: .small,
                action: openDiagnostics
            )
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                closeButton
                Spacer(minLength: 12)
                footerActions
            }
            VStack(alignment: .leading, spacing: 10) {
                closeButton
                footerActions
                    .frame(maxWidth: 320)
            }
        }
    }

    private var closeButton: some View {
        Button(appState.localized("닫기")) {
            dismiss()
        }
    }

    private var footerActions: some View {
        ResponsiveActionRow(alignment: .trailing) {
            if let logURL = payload.logURL {
                ThemedActionButton(
                    title: "로그 보기",
                    systemImage: "doc.text.magnifyingglass",
                    prominence: .secondary,
                    controlSize: .small
                ) {
                    appState.revealInFinder(logURL)
                }
            }
            ThemedActionButton(
                title: "문제 진단 (베타) 열기",
                systemImage: "stethoscope",
                prominence: .primary,
                controlSize: .small,
                action: openDiagnostics
            )
        }
    }

    private func showRuntimeUpdateGuidance() {
        let guidance = appState.localized(ForgePlayRuntimeCapabilityPolicy.runtimeUpdateGuidanceKey)
        runtimeUpdateMessage = guidance
        appState.setNotice(guidance, kind: .warning)
    }

    private func openDiagnostics() {
        appState.activeDiagnostics = payload.diagnostics
        appState.selectedSection = .diagnostics
        if opensMainWindowForNavigation {
            openWindow(id: ForgePlaySceneID.main)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        dismiss()
    }

    private func presentSheet(_ destination: SheetDestination) {
        if let sheetPresenter {
            sheetPresenter(destination)
        } else {
            appState.presentedSheet = destination
        }
    }

    private func symbolName(for action: RecommendedAction) -> String {
        switch action.type {
        case .installRuntime: "square.and.arrow.down"
        case .setWindowsVersion: "desktopcomputer"
        case .setDLLOverride: "puzzlepiece.extension"
        case .addLaunchOption: "text.badge.plus"
        case .askUserToUpdateRuntime: "arrow.down.app"
        case .markUnsupported: "exclamationmark.triangle"
        case .importAppleSupplementalRenderer: "shippingbox"
        case .askUserToUpdateMacOS: "gearshape.arrow.triangle.2.circlepath"
        case .noAction: "info.circle"
        }
    }
}

struct GuidedSelectionView: View {
    var title: String
    var subtitle: String
    var primaryTitle: String
    var primaryIcon: String
    var secondaryTitle: String?
    var secondaryIcon: String?
    var message: String
    var primaryDisabled = false
    var secondaryDisabled = false
    var secondaryDisabledReason: String?
    var tertiaryTitle: String? = nil
    var tertiaryIcon: String? = nil
    var tertiaryDisabled = false
    var primaryAction: () -> Void
    var secondaryAction: (() -> Void)?
    var tertiaryAction: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String,
        subtitle: String,
        primaryTitle: String,
        primaryIcon: String,
        secondaryTitle: String? = nil,
        secondaryIcon: String? = nil,
        message: String,
        primaryDisabled: Bool = false,
        secondaryDisabled: Bool = false,
        secondaryDisabledReason: String? = nil,
        primaryAction: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil,
        tertiaryTitle: String? = nil,
        tertiaryIcon: String? = nil,
        tertiaryDisabled: Bool = false,
        tertiaryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.primaryTitle = primaryTitle
        self.primaryIcon = primaryIcon
        self.secondaryTitle = secondaryTitle
        self.secondaryIcon = secondaryIcon
        self.message = message
        self.primaryDisabled = primaryDisabled
        self.secondaryDisabled = secondaryDisabled
        self.secondaryDisabledReason = secondaryDisabledReason
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.tertiaryTitle = tertiaryTitle
        self.tertiaryIcon = tertiaryIcon
        self.tertiaryDisabled = tertiaryDisabled
        self.tertiaryAction = tertiaryAction
    }

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(appState.localized(title))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(appState.localized(subtitle))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(appState.localized(message))
                    .font(.caption)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(palette.surfaceElevated)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: ForgePlayLayout.panelCornerRadius,
                            style: .continuous
                        )
                    )

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        Button(appState.localized("닫기")) { dismiss() }
                        Spacer(minLength: 12)
                        guidedActions
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Button(appState.localized("닫기")) { dismiss() }
                        guidedActions
                            .frame(maxWidth: 460)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 460, idealWidth: 560, maxWidth: 620, maxHeight: 720)
    }

    private var guidedActions: some View {
        Group {
            if let secondaryTitle, let secondaryIcon, let secondaryAction {
                VStack(alignment: .trailing, spacing: 10) {
                    ThemedActionButton(
                        title: primaryTitle,
                        systemImage: primaryIcon,
                        prominence: .primary,
                        isDisabled: primaryDisabled,
                        action: primaryAction
                    )
                    ThemedActionButton(
                        title: secondaryTitle,
                        systemImage: secondaryIcon,
                        prominence: .secondary,
                        isDisabled: secondaryDisabled,
                        action: secondaryAction
                    )
                    if let tertiaryTitle, let tertiaryIcon, let tertiaryAction {
                        ThemedActionButton(
                            title: tertiaryTitle,
                            systemImage: tertiaryIcon,
                            prominence: .secondary,
                            isDisabled: tertiaryDisabled,
                            action: tertiaryAction
                        )
                    }
                    if secondaryDisabled, let secondaryDisabledReason {
                        Text(appState.localized(secondaryDisabledReason))
                            .font(.caption2)
                            .foregroundStyle(ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme).secondaryText)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minWidth: 240, idealWidth: 320, maxWidth: 460, alignment: .trailing)
            } else {
                ThemedActionButton(
                    title: primaryTitle,
                    systemImage: primaryIcon,
                    prominence: .primary,
                    isDisabled: primaryDisabled,
                    action: primaryAction
                )
                    .frame(maxWidth: 280)
            }
        }
    }
}

private struct AppleSupplementalRendererImportView: View {
    var bundledRuntimePath: String?
    var importSupplementalRenderer: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(appState.localized("ForgePlay Runtime 확인"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(appState.localized(selectionSubtitleKey))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(palette.success)
                    .padding(.top, 2)
                Text(appState.localized("ForgePlay는 앱에 포함된 ForgePlay Runtime만 실행합니다. Apple 공식 D3DMetal 보조 렌더러를 가져와도 실행 엔진은 바뀌지 않습니다."))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.success.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(appState.localized("번들 실행 엔진"))
                            .font(.headline)
                            .foregroundStyle(palette.text)
                        SupplementalRendererGuideRow(
                            badge: "기본",
                            systemImage: "checkmark.seal.fill",
                            title: "ForgePlay Runtime",
                            detail: "앱 번들에 포함된 Wine 기반 실행 엔진입니다. Steam 클라이언트와 게임 프로세스 모두 이 Runtime에서 실행합니다."
                        )
                        SupplementalRendererGuideRow(
                            badge: "격리",
                            systemImage: "square.stack.3d.up.fill",
                            title: "Steam UI와 게임 렌더러 분리",
                            detail: "Windows용 Steam UI는 렌더러 주입 없이 기본 Wine 경로로 엽니다. 다음 실행 초안에는 그래픽 백엔드, 네트워크 표시, 오디오 입력, 동기화, 비디오 메모리, Game Mode 값이 함께 표시됩니다. 구성을 저장하거나 Steam을 실행하면 다음에도 다시 사용하며, 새 구성의 Game Mode 호스트 기본값은 켬입니다. 게임에는 선택한 백엔드 하나만 적용되고 D3DMetal NVIDIA는 GPU 공급자와 Apple MetalFX용 NGX 브리지를 함께 준비하는 실험 기능입니다."
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(appState.localized("Apple D3DMetal 보조 렌더러"))
                            .font(.headline)
                            .foregroundStyle(palette.text)
                        ForEach(SupplementalRendererDownloadOption.all) { option in
                            SupplementalRendererDownloadOptionRow(option: option)
                        }
                        SupplementalRendererGuideRow(
                            badge: "선택",
                            systemImage: "shippingbox",
                            title: "Evaluation environment for Windows games",
                            detail: "Apple 공식 DMG 또는 그 안의 redist 폴더를 선택합니다. ForgePlay는 D3DMetal 보조 파일만 관리형 앱 데이터에 복사합니다."
                        )
                        SupplementalRendererGuideRow(
                            badge: "자동",
                            systemImage: "externaldrive",
                            title: "중첩 DMG 읽기",
                            detail: "Finder에서 미리 열 필요 없이 읽기 전용으로 마운트하고 내부 Evaluation environment DMG까지 찾은 뒤 모두 해제합니다."
                        )
                        SupplementalRendererGuideRow(
                            badge: "유지",
                            systemImage: "lock.shield",
                            title: "ForgePlay Runtime 유지",
                            detail: "Evaluation environment redist를 가져와도 실행 엔진은 앱에 포함된 ForgePlay Runtime으로 유지됩니다."
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(appState.localized(selectionInstructionTitleKey))
                            .font(.headline)
                        Text(appState.localized(selectionInstructionDetailKey))
                            .font(.callout)
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(appState.localized("ForgePlay Runtime"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.secondaryText)
                        AdaptiveValueText(
                            text: bundledRuntimePath ?? appState.localized("앱에 포함된 ForgePlay Runtime을 찾지 못했습니다."),
                            font: .caption,
                            color: palette.secondaryText
                        )
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 560)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    Button(appState.localized("닫기")) { dismiss() }
                    Spacer(minLength: 12)
                    ThemedActionButton(
                        title: "Apple D3DMetal 보조 렌더러 가져오기",
                        systemImage: "shippingbox",
                        prominence: .primary,
                        isDisabled: !canImportSupplementalRenderer,
                        action: importSupplementalRenderer
                    )
                        .frame(maxWidth: 260)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Button(appState.localized("닫기")) { dismiss() }
                    ThemedActionButton(
                        title: "Apple D3DMetal 보조 렌더러 가져오기",
                        systemImage: "shippingbox",
                        prominence: .primary,
                        isDisabled: !canImportSupplementalRenderer,
                        action: importSupplementalRenderer
                    )
                        .frame(maxWidth: 260)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 820, maxWidth: 820, minHeight: 560, idealHeight: 720, maxHeight: 760)
    }

    private var canImportSupplementalRenderer: Bool {
        ForgePlayRuntimeCapabilityPolicy.canImportAppleSupplementalRenderer
    }

    private var selectionSubtitleKey: String {
        "ForgePlay Runtime은 그대로 유지하고, 사용자가 선택한 Apple D3DMetal 보조 렌더러만 게임 실행 경로에 연결합니다."
    }

    private var selectionInstructionTitleKey: String {
        "ForgePlay에서 선택할 항목"
    }

    private var selectionInstructionDetailKey: String {
        "Apple 공식 Evaluation environment for Windows games DMG 또는 redist 폴더만 선택할 수 있습니다."
    }
}

private struct SupplementalRendererDownloadOption: Identifiable {
    var id: String { title }
    var title: String
    var detail: String
    var buttonTitle: String
    var systemImage: String
    var url: URL

    static var all: [SupplementalRendererDownloadOption] {
        var options: [SupplementalRendererDownloadOption] = []
        if let url = ExternalLinkPolicy.appleGamePortingToolkitDownloadURL {
            options.append(SupplementalRendererDownloadOption(
                title: "Apple Game Porting Toolkit",
                detail: "Apple 공식 페이지에서 Game Porting Toolkit 또는 Evaluation environment를 받습니다. DMG는 ForgePlay가 자동 마운트해 검사합니다. Evaluation environment는 보조 라이브러리이며 단독 실행 엔진은 아닙니다.",
                buttonTitle: "Apple 페이지 열기",
                systemImage: "safari",
                url: url
            ))
        }
        return options
    }
}

private struct SupplementalRendererDownloadOptionRow: View {
    var option: SupplementalRendererDownloadOption
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                gameRunnerIcon(option)
                gameRunnerText(option)
                Spacer(minLength: 12)
                gameRunnerButton(option)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    gameRunnerIcon(option)
                    gameRunnerText(option)
                }
                gameRunnerButton(option)
                    .padding(.leading, 38)
            }
        }
        .padding(10)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
            )
    }

    private func gameRunnerIcon(_ option: SupplementalRendererDownloadOption) -> some View {
        Image(systemName: option.systemImage)
            .font(.title3)
            .foregroundStyle(palette.primary)
            .frame(width: 26)
    }

    private func gameRunnerText(_ option: SupplementalRendererDownloadOption) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.localized(option.title))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(appState.localized(option.detail))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func gameRunnerButton(_ option: SupplementalRendererDownloadOption) -> some View {
        ThemedActionButton(
            title: option.buttonTitle,
            systemImage: "arrow.up.forward.app",
            prominence: .secondary,
            controlSize: .small
        ) {
            appState.openExternalURL(option.url)
        }
        .frame(minWidth: 132, idealWidth: 156, maxWidth: 220)
    }
}

private struct SupplementalRendererGuideRow: View {
    var badge: String
    var systemImage: String
    var title: String
    var detail: String
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(palette.primary)
                .frame(width: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        guideTitle
                        guideBadge
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        guideTitle
                        guideBadge
                    }
                }
                Text(appState.localized(detail))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(12)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var guideTitle: some View {
        Text(appState.localized(title))
            .font(.headline)
            .foregroundStyle(palette.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var guideBadge: some View {
        Text(appState.localized(badge))
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(palette.primary.opacity(0.14))
            .clipShape(Capsule())
    }
}

private struct RuntimeInstallerCatalogSheet: View {
    var sheetPresenter: ((SheetDestination) -> Void)? = nil
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \PrefixRecord.displayName) private var prefixes: [PrefixRecord]
    @Query(sort: \RuntimeRecord.runtime) private var runtimes: [RuntimeRecord]
    private let runtimeCatalogFooterScrollInset: CGFloat = 88

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    private var canRunBundledWindowsRuntime: Bool {
        ForgePlayRuntimeCapabilityPolicy.canRunBundledWindowsRuntime
    }

    private var bundledRuntimeUnavailableReason: String {
        appState.localized(ForgePlayRuntimeCapabilityPolicy.unavailableReasonKey)
    }

    private var hasSteamPrefixRecord: Bool {
        prefixes.contains { $0.id == PrefixIdentifier.steamShared }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(appState.localized("필수 구성요소(Runtime) 설치"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(palette.text)
                Text(appState.localized("공식 다운로드 페이지에서 사용자가 받은 설치 파일만 선택합니다. ForgePlay는 설치 파일을 포함하거나 서버에서 내려받지 않습니다."))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(appState.localized("설치 흐름"))
                    .font(.headline)
                    .foregroundStyle(palette.text)
                RemediationStepsView(steps: [
                    "아래 목록에서 필요한 구성요소를 고릅니다.",
                    "공식 페이지를 열어 Microsoft, NVIDIA, OpenAL 등 원 출처에서 설치 파일을 받습니다.",
                    "설치 안내를 열고 ForgePlay에서 요구하는 최종 설치 파일을 선택합니다.",
                    "설치 대상은 Windows용 Steam이 들어 있는 Steam 프리픽스입니다.",
                    "ForgePlay가 Steam 프리픽스의 스냅샷을 만든 뒤 포함 Runtime으로 설치 파일을 실행합니다."
                ])
            }
            .padding(12)
            .background(palette.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(services.runtimeManager.definitions) { definition in
                        RuntimeCatalogRow(
                            definition: definition,
                            records: records(for: definition.id),
                            sheetPresenter: sheetPresenter
                        )
                    }
                }
                .padding(.trailing, 6)
                .padding(.bottom, runtimeCatalogFooterScrollInset)
            }
            .frame(maxHeight: 430)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Button(appState.localized("닫기")) {
                        dismiss()
                    }
                    Spacer(minLength: 12)
                    catalogFooterWarning
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button(appState.localized("닫기")) {
                        dismiss()
                    }
                    catalogFooterWarning
                }
            }
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 860, maxWidth: 860)
    }

    @ViewBuilder
    private var catalogFooterWarning: some View {
        if !canRunBundledWindowsRuntime {
            Text(bundledRuntimeUnavailableReason)
                .font(.caption)
                .foregroundStyle(palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if appState.runtimeExecutableURL == nil {
            Text(appState.localized("설치를 실행하려면 ForgePlay Runtime을 먼저 확인해야 합니다."))
                .font(.caption)
                .foregroundStyle(palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if !hasSteamPrefixRecord {
            Text(appState.localized("설치할 Steam 프리픽스가 없습니다. 설치 안내에서 먼저 만들 수 있습니다."))
                .font(.caption)
                .foregroundStyle(palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func records(for runtime: RuntimeId) -> [RuntimeRecord] {
        runtimes.filter { $0.runtime == runtime.rawValue }
    }
}

private struct RuntimeCatalogRow: View {
    var definition: RuntimeDefinition
    var records: [RuntimeRecord]
    var sheetPresenter: ((SheetDestination) -> Void)? = nil
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    private var canRunBundledWindowsRuntime: Bool {
        ForgePlayRuntimeCapabilityPolicy.canRunBundledWindowsRuntime
    }

    private var hasInstalledRecord: Bool {
        records.contains { $0.status == "installed" }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                runtimeIcon
                runtimeText
                Spacer(minLength: 12)
                runtimeActions
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    runtimeIcon
                    runtimeText
                }
                runtimeActions
                    .frame(maxWidth: 260)
                    .padding(.leading, 40)
            }
        }
        .padding(12)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
            )
    }

    private var runtimeIcon: some View {
        Image(systemName: "puzzlepiece.extension")
            .font(.title3)
            .foregroundStyle(palette.primary)
            .frame(width: 28)
            .padding(.top, 3)
    }

    private var runtimeText: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    runtimeTitle
                    StatusBadge(label: hasInstalledRecord ? "설치 기록 있음" : "필요 시 설치", status: hasInstalledRecord ? .ok : .unknown)
                }
                VStack(alignment: .leading, spacing: 6) {
                    runtimeTitle
                    StatusBadge(label: hasInstalledRecord ? "설치 기록 있음" : "필요 시 설치", status: hasInstalledRecord ? .ok : .unknown)
                }
            }
            Text(appState.localized(definition.beginnerDescription))
                .font(.callout)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(appState.localizedFormat("공식 출처: %@", definition.officialSourceName))
                Text(appState.localizedFormat("다운로드할 파일: %@", definition.downloadHintSummary))
                Text(appState.localizedFormat("ForgePlay에서 선택할 파일: %@", definition.installerHintSummary))
                if let firstNote = definition.preparationNotes.first {
                    Text(appState.localized(firstNote))
                }
            }
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
    }

    private var runtimeTitle: some View {
        Text(definition.id.localizedTitle(appState: appState))
            .font(.headline)
            .foregroundStyle(palette.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var runtimeActions: some View {
        VStack(spacing: 8) {
            ThemedActionButton(
                title: "공식 페이지",
                systemImage: "safari",
                prominence: .secondary,
                controlSize: .small
            ) {
                if let url = definition.officialURL {
                    appState.openExternalURL(url)
                }
            }

            ThemedActionButton(
                title: "설치 안내",
                systemImage: "square.and.arrow.down",
                prominence: .primary,
                isDisabled: !canRunBundledWindowsRuntime,
                controlSize: .small
            ) {
                if let sheetPresenter {
                    sheetPresenter(.chooseRuntimeInstaller(definition.id))
                } else {
                    appState.presentedSheet = .chooseRuntimeInstaller(definition.id)
                }
            }
        }
        .frame(minWidth: 148, idealWidth: 168, maxWidth: 240)
    }
}

private struct PreparedRuntimePrefix {
    var record: PrefixRecord
    var persistenceWarning: String?

    @MainActor
    func localizedDisplayName(appState: AppState) -> String {
        record.localizedDisplayName(appState: appState)
    }
}

private struct RuntimeInstallerSheet: View {
    var runtime: RuntimeId
    var sheetPresenter: ((SheetDestination) -> Void)? = nil
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \PrefixRecord.displayName) private var prefixes: [PrefixRecord]
    @State private var isPreparingSteamSharedPrefix = false

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    private var selectedPrefix: PrefixRecord? {
        prefixes.first { $0.id == PrefixIdentifier.steamShared }
    }

    private var canRunInstaller: Bool {
        canRunBundledWindowsRuntime && appState.runtimeExecutableURL != nil && selectedPrefix != nil
    }

    private var canRunBundledWindowsRuntime: Bool {
        ForgePlayRuntimeCapabilityPolicy.canRunBundledWindowsRuntime
    }

    private var bundledRuntimeUnavailableReason: String? {
        canRunBundledWindowsRuntime
            ? nil
            : appState.localized(ForgePlayRuntimeCapabilityPolicy.unavailableReasonKey)
    }

    var body: some View {
        let definition = services.runtimeManager.definition(for: runtime)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                Text(appState.localizedFormat("%@(%@) 설치", runtime.localizedName(appState: appState), runtime.technicalName))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(palette.text)
                Text(appState.localized(definition.beginnerDescription))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                Text(appState.localized("설치 대상 Steam 프리픽스"))
                    .font(.headline)
                    .foregroundStyle(palette.text)
                Text(appState.localized("ForgePlay는 게임을 Windows용 Steam에서 실행하므로 필수 구성요소도 Steam 프리픽스에 설치합니다. 이전 게임별 프리픽스는 현재 실행 경로에 사용하지 않습니다."))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let selectedPrefix {
                    StatusBadge(label: "Steam 프리픽스", status: .ok)
                    AdaptiveValueText(
                        text: selectedPrefix.path,
                        font: .system(.caption, design: .monospaced),
                        color: palette.secondaryText
                    )
                } else {
                    Text(appState.localized("아직 기록된 Steam 프리픽스가 없습니다. 아래 버튼으로 먼저 만들거나 설정에서 Steam 프리픽스를 만드세요."))
                        .font(.callout)
                        .foregroundStyle(palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ThemedActionButton(
                    title: "Steam 프리픽스 만들기/확인",
                    systemImage: "externaldrive.badge.plus",
                    prominence: .secondary,
                    isDisabled: !canRunBundledWindowsRuntime || isPreparingSteamSharedPrefix || appState.runtimeExecutableURL == nil,
                    controlSize: .small
                ) {
                    prepareSteamPrefix()
                }
                .frame(maxWidth: 260)
                }
                .padding(12)
                .background(palette.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.panelCornerRadius, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                Text(appState.localized("설치 절차"))
                    .font(.headline)
                    .foregroundStyle(palette.text)
                RemediationStepsView(steps: definition.localizedRemediationSteps(appState: appState))
                }

                ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    installerCloseButton
                    Spacer(minLength: 12)
                    installerFooterActions(definition: definition)
                }
                VStack(alignment: .leading, spacing: 10) {
                    installerCloseButton
                    installerFooterActions(definition: definition)
                        .frame(maxWidth: 460)
                }
                }

                installerWarning
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, idealWidth: 820, maxWidth: 820, maxHeight: 760)
    }

    private var installerCloseButton: some View {
        Button(appState.localized("닫기")) {
            dismiss()
        }
    }

    private func installerFooterActions(definition: RuntimeDefinition) -> some View {
        ResponsiveActionRow(alignment: .trailing) {
            ThemedActionButton(
                title: "공식 다운로드 페이지 열기",
                systemImage: "safari",
                prominence: .secondary
            ) {
                if let url = definition.officialURL {
                    appState.openExternalURL(url)
                }
            }

            ThemedActionButton(
                title: "설치 파일 선택 후 실행",
                systemImage: "square.and.arrow.down",
                prominence: .primary,
                isDisabled: !canRunInstaller
            ) {
                chooseInstallerAndRun()
            }
        }
        .frame(maxWidth: 520)
    }

    @ViewBuilder
    private var installerWarning: some View {
        if let bundledRuntimeUnavailableReason {
            Text(bundledRuntimeUnavailableReason)
                .font(.caption)
                .foregroundStyle(palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if appState.runtimeExecutableURL == nil {
            Text(appState.localized("설치를 실행하려면 ForgePlay Runtime을 먼저 확인해야 합니다."))
                .font(.caption)
                .foregroundStyle(palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if selectedPrefix == nil {
            Text(appState.localized("설치할 Steam 프리픽스를 먼저 생성하세요."))
                .font(.caption)
                .foregroundStyle(palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseInstallerAndRun() {
        let definition = services.runtimeManager.definition(for: runtime)
        if let bundledRuntimeUnavailableReason {
            appState.setNotice(bundledRuntimeUnavailableReason, kind: .warning)
            return
        }
        guard let runtimeExecutable = appState.runtimeExecutableURL else {
            appState.setNotice(appState.localized("ForgePlay Runtime을 먼저 확인하세요."), kind: .warning)
            return
        }
        guard let selectedPrefix else {
            appState.setNotice(appState.localized("설치할 Steam 프리픽스를 먼저 생성하세요."), kind: .warning)
            return
        }
        guard let installer = OpenPanelPresenter.chooseFile(
            title: appState.localizedFormat("%@ 설치 파일 선택", runtime.localizedTitle(appState: appState)),
            message: definition.localizedSelectionPanelMessage(appState: appState),
            prompt: appState.localized("설치 파일 선택"),
            allowedExtensions: RuntimeManager.allowedInstallerExtensions
        ) else { return }
        let isInstallableFile = services.runtimeManager.isInstaller(installer, plausibleFor: runtime)
        let isExtractableArchive = services.runtimeManager.isExtractionArchive(installer, plausibleFor: runtime)
        guard isInstallableFile || isExtractableArchive else {
            appState.setNotice(
                appState.localizedFormat("선택한 설치 파일이 이 필수 구성요소와 맞지 않습니다. 선택 가능한 파일: %@", definition.selectableFileSummary),
                kind: .warning
            )
            return
        }

        appState.setTask(appState.localizedFormat("%@을 확인하는 중입니다.", selectedPrefix.localizedDisplayName(appState: appState)))
        Task {
            var prefixPersistenceWarning: String?
            do {
                let preparedPrefix = try await preparePrefix(selectedPrefix, runtimeExecutable: runtimeExecutable)
                prefixPersistenceWarning = preparedPrefix.persistenceWarning
                let prefix = URL(fileURLWithPath: preparedPrefix.record.path)
                let result = try await services.steamPrefixService
                    .performCancellableProcessMaintenance {
                    try await services.runtimeManager.withQuiescentPrefixMutation(
                        runtimeExecutable: runtimeExecutable,
                        prefixURL: prefix,
                        operationDescription: "runtime install \(runtime.rawValue)"
                    ) {
                        _ = try await services.prefixManager.snapshot(
                            prefixURL: prefix,
                            reason: "before-\(runtime.rawValue)"
                        )
                        let result: ProcessRunResult
                        if isExtractableArchive {
                            appState.setTask(appState.localizedFormat("%@ 설치 파일 압축을 푸는 중입니다.", runtime.localizedName(appState: appState)))
                            result = try await services.runtimeManager.withExtractedInstaller(
                                runtime: runtime,
                                archive: installer,
                                runtimeExecutable: runtimeExecutable,
                                prefixURL: prefix
                            ) { extraction in
                                try await runRuntimeInstaller(
                                    runtime,
                                    installer: extraction.installer,
                                    runtimeExecutable: runtimeExecutable,
                                    prefix: prefix,
                                    prefixDisplayName: preparedPrefix.localizedDisplayName(appState: appState)
                                )
                            }
                        } else {
                            result = try await runRuntimeInstaller(
                                runtime,
                                installer: installer,
                                runtimeExecutable: runtimeExecutable,
                                prefix: prefix,
                                prefixDisplayName: preparedPrefix.localizedDisplayName(appState: appState)
                            )
                        }
                        if result.succeeded {
                            try services.prefixManager.markRuntimeInstalled(runtime, prefixURL: prefix)
                        }
                        return result
                    }
                }
                if result.succeeded {
                    do {
                        let syncedPrefix = try syncPrefixRecord(at: prefix)
                        try saveRuntimeRecord(runtime, prefixRecord: syncedPrefix, result: result)
                        let message = appState.localizedFormat("%@ 설치가 끝났습니다.", runtime.localizedName(appState: appState))
                        let notice = appState.setNotice(
                            DiagnosticWarningText.combined(message, preparedPrefix.persistenceWarning) ?? message,
                            kind: preparedPrefix.persistenceWarning == nil ? .success : .warning
                        )
                        clearTaskLater(notice.id)
                    } catch let persistenceError {
                        modelContext.rollback()
                        let message = appState.localizedFormat(
                            "%@ 설치는 끝났지만 Steam 프리픽스 기록을 저장하지 못했습니다: %@",
                            runtime.localizedName(appState: appState),
                            forgePlayTechnicalErrorSummary(persistenceError)
                        )
                        appState.setNotice(
                            DiagnosticWarningText.combined(message, preparedPrefix.persistenceWarning) ?? message,
                            kind: .warning,
                            logURL: result.stdoutLog
                        )
                    }
                } else if result.didTimeOut {
                    let failureMessage = appState.localizedFormat(
                        "%@ 설치 시간이 너무 오래 걸려 중단했습니다. 로그를 확인하세요: %@",
                        runtime.localizedName(appState: appState),
                        result.stderrLog.path
                    )
                    let persistenceWarning = saveRuntimeFailureRecordWarning(
                        runtime,
                        prefixRecord: preparedPrefix.record,
                        result: result
                    )
                    presentGuidance(
                        result: result,
                        fallbackReason: failureMessage,
                        prefixPersistenceWarning: preparedPrefix.persistenceWarning
                    )
                    appState.setNotice(
                        DiagnosticWarningText.combined(
                            failureMessage,
                            preparedPrefix.persistenceWarning,
                            persistenceWarning
                        ) ?? failureMessage,
                        kind: .failure,
                        logURL: result.stderrLog,
                        diagnosticProcessResult: result
                    )
                } else {
                    let failureMessage = appState.localizedFormat(
                        "%@ 설치에 실패했습니다. 로그를 확인하세요: %@",
                        runtime.localizedName(appState: appState),
                        result.stderrLog.path
                    )
                    let persistenceWarning = saveRuntimeFailureRecordWarning(
                        runtime,
                        prefixRecord: preparedPrefix.record,
                        result: result
                    )
                    presentGuidance(
                        result: result,
                        fallbackReason: failureMessage,
                        prefixPersistenceWarning: preparedPrefix.persistenceWarning
                    )
                    appState.setNotice(
                        DiagnosticWarningText.combined(
                            failureMessage,
                            preparedPrefix.persistenceWarning,
                            persistenceWarning
                        ) ?? failureMessage,
                        kind: .failure,
                        logURL: result.stderrLog,
                        diagnosticProcessResult: result
                    )
                }
            } catch {
                let result = processRunResult(from: error)
                if let result {
                    presentGuidance(
                        result: result,
                        fallbackReason: appState.localizedFormat(
                            "%@ 설치 준비 단계에서 실패했습니다. ForgePlay Runtime과 Steam 프리픽스를 다시 확인하세요.",
                            runtime.localizedName(appState: appState)
                        ),
                        prefixPersistenceWarning: prefixPersistenceWarning
                    )
                }
                if let prefixPersistenceWarning {
                    let message = appState.localizedError(error)
                    appState.setNotice(
                        DiagnosticWarningText.combined(message, prefixPersistenceWarning) ?? message,
                        kind: .failure,
                        logURL: result?.stderrLog,
                        diagnosticProcessResult: result
                    )
                } else {
                    appState.setError(error)
                }
            }
        }
        dismiss()
    }

    private func prepareSteamPrefix() {
        if let bundledRuntimeUnavailableReason {
            appState.setNotice(bundledRuntimeUnavailableReason, kind: .warning)
            return
        }
        guard let runtimeExecutable = appState.runtimeExecutableURL else {
            appState.setNotice(appState.localized("ForgePlay Runtime을 먼저 확인하세요."), kind: .warning)
            return
        }
        guard !isPreparingSteamSharedPrefix else { return }
        isPreparingSteamSharedPrefix = true
        appState.setTask(appState.localized("Steam 프리픽스를 확인하는 중입니다."))
        Task {
            defer { isPreparingSteamSharedPrefix = false }
            do {
                let preparation = try await services.prepareSteamPrefix(
                    runtimeExecutable: runtimeExecutable,
                    synchronizationSelection: appState.wineSynchronizationSelection
                )
                let savedPrefix = savePrefixRecordWarning(metadata: preparation.metadata)
                let preparationWarning = DiagnosticWarningText.combined(
                    savedPrefix.warning,
                    preparation.localizedPreviousEnvironmentCleanupWarning(appState: appState)
                )
                let message = appState.localized("Steam 프리픽스가 준비되었습니다.")
                let notice = appState.setNotice(
                    DiagnosticWarningText.combined(message, preparationWarning) ?? message,
                    kind: preparationWarning == nil ? .success : .warning
                )
                clearTaskLater(notice.id)
            } catch {
                if let result = processRunResult(from: error) {
                    presentGuidance(
                        result: result,
                        fallbackReason: appState.localized("Steam 프리픽스 준비 단계에서 실패했습니다. ForgePlay Runtime과 저장 위치를 다시 확인하세요.")
                    )
                }
                appState.setError(error)
            }
        }
    }

    private func runRuntimeInstaller(
        _ runtime: RuntimeId,
        installer: URL,
        runtimeExecutable: URL,
        prefix: URL,
        prefixDisplayName: String
    ) async throws -> ProcessRunResult {
        appState.setTask(appState.localizedFormat(
            "%@을 %@에 설치하는 중입니다.",
            runtime.localizedName(appState: appState),
            prefixDisplayName
        ))
        let result = try await services.runtimeManager.install(
            runtime: runtime,
            installer: installer,
            runtimeExecutable: runtimeExecutable,
            prefixURL: prefix
        )
        return result
    }

    private func preparePrefix(_ prefixRecord: PrefixRecord, runtimeExecutable: URL) async throws -> PreparedRuntimePrefix {
        guard prefixRecord.id == PrefixIdentifier.steamShared else {
            throw RuntimeInstallerError.unusablePrefix(appState.localized(PrefixMode.legacy("").beginnerName))
        }
        let preparation = try await services.prepareSteamPrefix(
            runtimeExecutable: runtimeExecutable,
            synchronizationSelection: appState.wineSynchronizationSelection
        )
        let savedPrefix = savePrefixRecordWarning(metadata: preparation.metadata)
        return PreparedRuntimePrefix(
            record: savedPrefix.record ?? prefixRecord,
            persistenceWarning: DiagnosticWarningText.combined(
                savedPrefix.warning,
                preparation.localizedPreviousEnvironmentCleanupWarning(appState: appState)
            )
        )
    }

    private func savePrefixRecordWarning(metadata: PrefixMetadata) -> (record: PrefixRecord?, warning: String?) {
        do {
            let record = try PrefixRecord.upsert(metadata: metadata, in: modelContext)
            try modelContext.saveOrRollback()
            return (record, nil)
        } catch {
            modelContext.rollback()
            return (
                nil,
                appState.localizedFormat(
                    "Steam 프리픽스는 준비됐지만 기록을 저장하지 못했습니다: %@",
                    forgePlayTechnicalErrorSummary(error)
                )
            )
        }
    }

    private func saveRuntimeRecord(
        _ runtime: RuntimeId,
        prefixRecord: PrefixRecord,
        result: ProcessRunResult
    ) throws {
        let id = "\(prefixRecord.id)-\(runtime.rawValue)"
        let existing = try modelContext.fetch(FetchDescriptor<RuntimeRecord>())
        let record = existing.first { $0.id == id } ?? RuntimeRecord(id: id, prefixId: prefixRecord.id, runtime: runtime)
        record.status = result.succeeded ? "installed" : "failed"
        record.installedAt = result.succeeded ? Date() : nil
        record.installerSource = "user-selected"
        record.installLogPath = result.succeeded
            ? result.stdoutLog.path
            : result.preferredDiagnosticLog.path
        if existing.first(where: { $0.id == id }) == nil {
            modelContext.insert(record)
        }
        try modelContext.saveOrRollback()
    }

    private func saveRuntimeFailureRecordWarning(
        _ runtime: RuntimeId,
        prefixRecord: PrefixRecord,
        result: ProcessRunResult
    ) -> String? {
        do {
            try saveRuntimeRecord(runtime, prefixRecord: prefixRecord, result: result)
            return nil
        } catch {
            modelContext.rollback()
            return appState.localizedFormat(
                "%@ 설치 결과 기록을 저장하지 못했습니다: %@",
                runtime.localizedName(appState: appState),
                forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    @discardableResult
    private func syncPrefixRecord(at prefixURL: URL) throws -> PrefixRecord {
        let metadata = try services.prefixManager.loadMetadata(at: prefixURL)
        let record = try PrefixRecord.upsert(metadata: metadata, in: modelContext)
        try modelContext.saveOrRollback()
        return record
    }

    private func presentGuidance(
        result: ProcessRunResult,
        fallbackReason: String,
        prefixPersistenceWarning: String? = nil
    ) {
        let logSnapshot = LogTextReader.diagnosticSnapshot(from: [result.stdoutLog, result.stderrLog])
        let diagnostics = DiagnosticGuidanceBuilder.diagnostics(
            ruleEngine: services.ruleEngine,
            logText: logSnapshot.text,
            context: .setupOrInstaller,
            language: appState.effectiveLanguageMode,
            fallbackReason: fallbackReason
        )
        let persistenceWarning = saveDiagnosticRecords(diagnostics)
        guard let destination = appState.diagnosticGuideDestination(
            title: runtime.localizedName(appState: appState),
            diagnostics: diagnostics,
            logURL: result.stderrLog,
            persistenceWarning: DiagnosticWarningText.combined(
                logSnapshot.readError.map { appState.localizedError($0) },
                prefixPersistenceWarning,
                persistenceWarning
            )
        ) else { return }
        presentSheet(destination)
    }

    private func presentSheet(_ destination: SheetDestination) {
        if let sheetPresenter {
            sheetPresenter(destination)
        } else {
            appState.presentedSheet = destination
        }
    }

    private func saveDiagnosticRecords(_ diagnostics: [DiagnosticResult]) -> String? {
        do {
            try modelContext.saveDiagnosticRecords(diagnostics)
            return nil
        } catch {
            return appState.localizedFormat("진단 결과를 저장하지 못했습니다: %@", forgePlayTechnicalErrorSummary(error))
        }
    }

    private func processRunResult(from error: Error) -> ProcessRunResult? {
        diagnosticProcessRunResult(from: error)
    }

    private func clearTaskLater(_ noticeID: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(3))
            appState.clearNotice(id: noticeID)
        }
    }
}

enum RuntimeInstallerError: LocalizedError {
    case unusablePrefix(String)

    var errorDescription: String? {
        switch self {
        case .unusablePrefix:
            "선택한 Steam 프리픽스를 사용할 수 없습니다."
        }
    }
}
