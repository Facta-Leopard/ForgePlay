import SwiftData
import SwiftUI

private enum SetupStepVisualState: Equatable {
    case complete
    case current
    case blocked
    case pending

    var status: CheckStatus {
        switch self {
        case .complete: .ok
        case .current: .warning
        case .blocked: .error
        case .pending: .unknown
        }
    }

    var symbolName: String {
        switch self {
        case .complete: "checkmark.circle.fill"
        case .current: "arrow.right.circle.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .pending: "circle"
        }
    }
}

struct SetupView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \SteamGameRecord.name) private var games: [SteamGameRecord]
    @Query(sort: \LaunchRecord.startedAt, order: .reverse) private var launchRecords: [LaunchRecord]
    @State private var isShowingSteamPrefixConfirmation = false
    @State private var isCreatingSteamPrefix = false
    @State private var isApplyingRendererPolicy = false
    @State private var expandedStage: SetupStage?

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    private var readiness: SetupReadiness {
        appState.setupReadiness
    }

    private var canRunBundledWindowsRuntime: Bool {
        ForgePlayRuntimeCapabilityPolicy.canRunBundledWindowsRuntime
    }

    private var bundledRuntimeUnavailableReasonKey: String? {
        canRunBundledWindowsRuntime
            ? nil
            : ForgePlayRuntimeCapabilityPolicy.unavailableReasonKey
    }

    private var bundledRuntimeUnavailableReason: String? {
        bundledRuntimeUnavailableReasonKey.map(appState.localized)
    }

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        ForgePageScaffold(
            "처음 설정",
            subtitle: "필수 단계를 순서대로 완료하면 Windows용 Steam을 실행할 수 있습니다.",
            systemImage: "checklist"
        ) {
            SectionHelpButton(section: .setup)
        } content: {
            setupProgressSummary(palette: palette)
            currentActionCard
            stepList
        }
        .task {
            await refreshChecksAndProgress()
        }
        .onChange(of: games.count) { _, _ in
            refreshProgress()
        }
        .onChange(of: SteamLaunchRecordLookup.stateFingerprint(from: launchRecords)) { _, _ in
            refreshProgress()
        }
        .onChange(of: services.steamEnvironmentRevision) { _, _ in
            refreshProgress()
        }
        .onChange(of: appState.setupStage) { _, _ in
            expandedStage = nil
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
    }

    private func setupProgressSummary(palette: ForgePlayPalette) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: setupProgress)
                .tint(palette.primary)
                .accessibilityLabel(appState.localized("설정 진행률"))
            Text(appState.localizedFormat(
                "%d / %d 단계 완료",
                completedSetupStageCount,
                SetupStage.allCases.count
            ))
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.secondaryText)
                .fixedSize()
        }
        .padding(.horizontal, 2)
    }

    private var completedSetupStageCount: Int {
        SetupStage.allCases.filter { visualState(for: $0) == .complete }.count
    }

    private var currentActionCard: some View {
        ForgeWorkflowActionPanel(
            eyebrow: appState.setupStage == .ready ? "설정 완료" : "현재 단계",
            title: appState.setupStage.title,
            detail: appState.setupStage.beginnerDescription,
            status: status(for: appState.setupStage),
            systemImage: appState.setupStage.symbolName
        ) {
            VStack(alignment: .trailing, spacing: 6) {
                recommendedAction
                    .frame(maxWidth: 360)
                if let currentBlocker = blockedReason(for: appState.setupStage) {
                    Text(appState.localized(currentBlocker))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private var recommendedAction: some View {
        switch appState.setupStage {
        case .chooseRoot:
            NativeActionButton(title: "앱 데이터 위치 보기", systemImage: "folder", prominence: .primary) {
                appState.presentedSheet = .chooseRoot
            }
        case .checkMac:
            NativeActionButton(
                title: services.setupWorkflowCoordinator.isSystemCheckInProgress
                    ? "Mac 상태 확인 중"
                    : "Mac 상태 다시 확인",
                systemImage: "checkmark.shield",
                prominence: .primary,
                isDisabled: services.setupWorkflowCoordinator.isSystemCheckInProgress
            ) {
                Task { await refreshChecksAndProgress() }
            }
        case .prepareEngine:
            NativeActionButton(
                title: "ForgePlay Runtime 확인",
                systemImage: "shippingbox",
                prominence: .primary,
                isDisabled: !canRunBundledWindowsRuntime ||
                    services.setupWorkflowCoordinator.isSystemCheckInProgress
            ) {
                Task { await refreshChecksAndProgress() }
            }
        case .prepareSteamEnvironment:
            NativeActionButton(
                title: isCreatingSteamPrefix ? "Steam 프리픽스 생성 중" : "Steam 프리픽스 만들기",
                systemImage: "externaldrive.badge.plus",
                prominence: .primary,
                isDisabled: !canRunBundledWindowsRuntime || isCreatingSteamPrefix || services.steamPrefixLifecycleCoordinator.isBusy
            ) {
                requestSteamPrefixCreation()
            }
        case .installSteam:
            NativeActionButton(
                title: "Windows용 Steam 설치",
                systemImage: "square.and.arrow.down",
                prominence: .primary,
                isDisabled: !canRunBundledWindowsRuntime
            ) {
                appState.presentedSheet = .chooseSteamInstaller
            }
        case .configureRenderer:
            NativeActionButton(
                title: rendererPolicySetupActionTitleKey,
                systemImage: "display",
                prominence: .primary,
                isDisabled: isRendererPolicyActionDisabled || services.steamPrefixLifecycleCoordinator.isBusy
            ) {
                applyRendererPolicy()
            }
        case .authenticateSteam:
            NativeActionButton(
                title: "Steam 로그인 화면 열기",
                systemImage: "person.crop.circle.badge.checkmark",
                prominence: .primary,
                isDisabled: !readiness.canAttemptWindowsSteamLaunch
            ) {
                appState.selectedSection = .steamLaunch
            }
        case .connectLibrary:
            NativeActionButton(
                title: steamReferenceRefreshActionTitleKey,
                systemImage: "arrow.clockwise",
                prominence: .secondary,
                isDisabled: services.isSteamReferenceRefreshInProgress ||
                    appState.steamStorageOperationMountID != nil ||
                    services.steamPrefixLifecycleCoordinator.isBusy
            ) {
                refreshSteamReferences()
            }
        case .ready:
            NativeActionButton(title: "Steam 실행 화면으로 이동", systemImage: "play.circle", prominence: .primary) {
                appState.selectedSection = .steamLaunch
            }
        }
    }

    private var stepList: some View {
        ForgeSection(
            "전체 설정 단계",
            subtitle: "완료한 단계는 접어 두고, 필요할 때 다시 열어 관리할 수 있습니다.",
            systemImage: "list.number"
        ) {
            VStack(spacing: 0) {
                ForEach(SetupStage.allCases) { stage in
                    SetupStepRow(
                        stage: stage,
                        state: visualState(for: stage),
                        detail: detail(for: stage),
                        technicalHint: technicalHint(for: stage),
                        blockedReason: blockedReason(for: stage),
                        isExpanded: expandedStage == stage,
                        toggleExpanded: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                expandedStage = expandedStage == stage ? nil : stage
                            }
                        },
                        action: { action(for: stage) }
                    )
                    if stage != SetupStage.allCases.last {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func action(for stage: SetupStage) -> some View {
        switch stage {
        case .chooseRoot:
            NativeActionButton(title: "보기", systemImage: "folder", prominence: .secondary) {
                appState.presentedSheet = .chooseRoot
            }
        case .checkMac:
            NativeActionButton(
                title: services.setupWorkflowCoordinator.isSystemCheckInProgress ? "확인 중" : "확인",
                systemImage: "checkmark.shield",
                prominence: .secondary,
                isDisabled: services.setupWorkflowCoordinator.isSystemCheckInProgress
            ) {
                Task { await refreshChecksAndProgress() }
            }
        case .prepareEngine:
            NativeActionButton(
                title: services.setupWorkflowCoordinator.isSystemCheckInProgress ? "확인 중" : "확인",
                systemImage: "shippingbox",
                prominence: .secondary,
                isDisabled: !canRunBundledWindowsRuntime ||
                    appState.selectedRootURL == nil ||
                    services.setupWorkflowCoordinator.isSystemCheckInProgress
            ) {
                Task { await refreshChecksAndProgress() }
            }
        case .prepareSteamEnvironment:
            NativeActionButton(
                title: isCreatingSteamPrefix ? "생성 중" : "만들기",
                systemImage: "externaldrive.badge.plus",
                prominence: .secondary,
                isDisabled: !canRunBundledWindowsRuntime || readiness.rootIssue != nil || appState.runtimeExecutableURL == nil || isCreatingSteamPrefix || services.steamPrefixLifecycleCoordinator.isBusy
            ) {
                requestSteamPrefixCreation()
            }
        case .installSteam:
            NativeActionButton(title: "설치", systemImage: "square.and.arrow.down", prominence: .secondary, isDisabled: !canRunBundledWindowsRuntime || readiness.rootIssue != nil || !readiness.hasSteamPrefix || appState.runtimeExecutableURL == nil || services.steamPrefixLifecycleCoordinator.isBusy) {
                appState.presentedSheet = .chooseSteamInstaller
            }
        case .configureRenderer:
            NativeActionButton(
                title: rendererPolicyActionTitleKey,
                systemImage: "display",
                prominence: .secondary,
                isDisabled: isRendererPolicyActionDisabled || appState.runtimeExecutableURL == nil || !readiness.hasSteamPrefix || services.steamPrefixLifecycleCoordinator.isBusy
            ) {
                applyRendererPolicy()
            }
        case .authenticateSteam:
            NativeActionButton(
                title: "Steam 실행 화면",
                systemImage: "person.crop.circle.badge.checkmark",
                prominence: .secondary,
                isDisabled: !readiness.canAttemptWindowsSteamLaunch
            ) {
                appState.selectedSection = .steamLaunch
            }
        case .connectLibrary:
            NativeActionButton(
                title: services.isSteamReferenceRefreshInProgress ? "찾는 중" : "새로고침",
                systemImage: "arrow.clockwise",
                prominence: .secondary,
                isDisabled: services.isSteamReferenceRefreshInProgress ||
                    appState.steamStorageOperationMountID != nil ||
                    services.steamPrefixLifecycleCoordinator.isBusy ||
                    appState.selectedRootURL == nil ||
                    readiness.rootIssue != nil
            ) {
                refreshSteamReferences()
            }
        case .ready:
            NativeActionButton(title: "Steam 실행", systemImage: "play.circle", prominence: .secondary) {
                appState.selectedSection = .steamLaunch
            }
        }
    }

    private var setupProgress: Double {
        let completed = SetupStage.allCases.filter { visualState(for: $0) == .complete }.count
        return Double(completed) / Double(SetupStage.allCases.count)
    }

    private func visualState(for stage: SetupStage) -> SetupStepVisualState {
        let status = status(for: stage)
        if status == .ok { return .complete }
        if stage == appState.setupStage { return status == .error ? .blocked : .current }
        return stage.rawValue < appState.setupStage.rawValue ? .blocked : .pending
    }

    private func status(for stage: SetupStage) -> CheckStatus {
        switch stage {
        case .chooseRoot:
            if readiness.rootIssue != nil { return .error }
            return appState.selectedRootURL == nil ? .warning : .ok
        case .checkMac:
            return appState.systemCheckSummary.allowsSetupProgress
                ? .ok
                : appState.systemCheckSummary.displayStatus
        case .prepareEngine:
            guard let runtimeExecutable = appState.runtimeExecutableURL else { return .warning }
            do {
                let capability = try services.windowsRuntimeService.inspectRuntimeCapability(executable: runtimeExecutable)
                return SteamClientCompatibilityVerifier.verify(capability: capability).canLaunchWindowsSteam ? .ok : .error
            } catch {
                return .error
            }
        case .prepareSteamEnvironment:
            if readiness.steamPrefixIssue != nil { return .error }
            return readiness.hasSteamPrefix ? .ok : .warning
        case .installSteam:
            return readiness.hasSteamExecutable ? .ok : .warning
        case .configureRenderer:
            guard let rendererInspection = readiness.rendererInspection else { return .warning }
            if rendererInspection.effectiveRecoveryKind == .runtimeUnavailable {
                return .error
            }
            if rendererInspection.requiresRepair { return .error }
            if rendererInspection.requiresApply { return .warning }
            return rendererInspection.status
        case .authenticateSteam:
            if readiness.steamUIVerificationState == .blackScreenSuspected ||
                readiness.steamUIVerificationState == .failed {
                return .error
            }
            return readiness.hasUsableAuthenticatedSteamSession ? .ok : .warning
        case .connectLibrary:
            return appState.selectedRootURL == nil || readiness.rootIssue != nil ? .warning : .ok
        case .ready:
            return readiness.rootIssue == nil &&
                appState.selectedRootURL != nil &&
                appState.runtimeExecutableURL != nil &&
                readiness.hasSteamPrefix &&
                readiness.hasSteamExecutable &&
                readiness.hasUsableAuthenticatedSteamSession &&
                readiness.hasAppliedRendererPolicyForSteam ? .ok : .warning
        }
    }

    private func detail(for stage: SetupStage) -> String {
        switch stage {
        case .chooseRoot:
            if let issue = readiness.rootIssue { return appState.localizedError(issue) }
            return appState.selectedRootURL?.path ?? appState.localized("앱 데이터 위치를 준비하는 중입니다.")
        case .checkMac:
            let summary = appState.systemCheckSummary
            if summary.phase == .unverified {
                return appState.localized("앱 데이터를 준비한 뒤 Mac 상태를 확인합니다.")
            }
            if !summary.blockingResults.isEmpty {
                return summary.blockingResults.map { appState.localized($0.detail) }.joined(separator: " ")
            }
            return summary.phase == .readyWithWarnings
                ? appState.localized("기본 실행 조건을 만족하며 확인할 권장 사항이 있습니다.")
                : appState.localized("이 Mac은 현재 ForgePlay 기본 조건을 만족합니다.")
        case .prepareEngine:
            guard let runtimeExecutable = appState.runtimeExecutableURL else {
                return appState.localized("앱에 포함된 ForgePlay Runtime을 찾지 못했습니다. Runtime 포함 빌드인지 확인하세요.")
            }
            do {
                let verification = try services.steamPrefixService.inspectSteamClientCompatibility(runtimeExecutable)
                if !verification.canLaunchWindowsSteam {
                    return appState.localized(verification.userMessage)
                }
                if !verification.canLaunchManagedSteamGames {
                    let productRuntimeName = appState.localized(
                        WindowsRuntimeDisplayName.productRuntimeName(for: verification.capability)
                    )
                    return appState.localizedFormat(
                        "%@ · %@. Steam 클라이언트 실행은 가능하지만 게임 렌더러 payload는 실행 전에 별도로 확인하세요.",
                        productRuntimeName,
                        appState.localized(WindowsRuntimeDisplayName.statusSummary(for: verification.capability))
                    )
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
        case .prepareSteamEnvironment:
            if let issue = readiness.steamPrefixIssue { return appState.localizedError(issue) }
            if readiness.hasSteamPrefix { return appState.localized("Steam을 설치할 Steam 프리픽스가 준비되어 있습니다.") }
            return appState.localized("Windows용 Steam을 담을 안전한 Steam 프리픽스를 먼저 만듭니다.")
        case .installSteam:
            if readiness.hasSteamExecutable { return appState.localized("Steam 실행 파일을 찾았습니다.") }
            return appState.localized("SteamSetup.exe는 사용자가 공식 Steam 페이지에서 직접 받은 파일만 사용합니다.")
        case .configureRenderer:
            return readiness.rendererInspection?.userMessage
                ?? appState.localized("Steam 실행 경로와 게임 렌더러 payload를 확인해야 합니다.")
        case .authenticateSteam:
            if readiness.steamUISurface == .steamGuard {
                return appState.localized("Steam Guard 인증을 완료한 뒤 라이브러리 화면을 기록하세요.")
            }
            if readiness.steamUISurface == .signIn {
                return appState.localized("로그인 화면은 확인됐습니다. Windows Steam에서 로그인한 뒤 라이브러리 화면을 기록하세요.")
            }
            if readiness.hasUsableAuthenticatedSteamSession {
                return appState.localized("인증 후 Windows Steam 라이브러리 화면이 확인됐습니다.")
            }
            if readiness.hasDetectedSteamAccountSession {
                return appState.localized("Steam 프리픽스에 로컬 계정 데이터가 있지만 인증 세션이 유효한지는 확인되지 않았습니다. Steam을 실행해 라이브러리를 확인하세요.")
            }
            return appState.localized("Windows용 Steam을 실행해 로그인하고 라이브러리 화면이 열리는지 확인하세요.")
        case .connectLibrary:
            return games.isEmpty ? appState.localized("선택 사항입니다. 외장 Steam 라이브러리를 연결하거나 Steam 참고 목록을 새로고침할 수 있습니다.") : appState.localizedFormat("%d개 Steam 참고 기록이 있습니다.", games.count)
        case .ready:
            return appState.localized("설정이 완료되었습니다. Steam 실행 화면에서 Windows용 Steam을 열 수 있습니다.")
        }
    }

    private func technicalHint(for stage: SetupStage) -> String {
        switch stage {
        case .chooseRoot:
            return appState.localized("앱 데이터 관리: Prefixes, RuntimeCache, Logs, Snapshots, Config · 외장: 사용자가 선택한 Steam 게임 라이브러리")
        case .checkMac:
            return appState.localized("요구 사항: macOS 26+, Apple Silicon, 쓰기 가능한 저장소")
        case .prepareEngine:
            return appState.localized("앱에 포함된 ForgePlay Runtime만 실행 엔진으로 사용")
        case .prepareSteamEnvironment:
            if readiness.steamPrefixIssue != nil { return appState.localized("Steam 프리픽스 metadata와 초기화 파일을 확인하세요.") }
            return appState.localizedFormat("Steam 프리픽스: %@", steamPrefixTargetPath)
        case .installSteam:
            return appState.localized("Steam 경로: drive_c/Program Files (x86)/Steam/steam.exe")
        case .configureRenderer:
            guard let inspection = readiness.rendererInspection else {
                return appState.localized("Steam launch path: not inspected")
            }
            return [
                appState.localizedFormat(
                    "게임 렌더러 payload: %@",
                    inspection.resolvedPolicy?.rawValue ?? "unresolved"
                ),
                appState.localizedFormat("적용된 모듈: %@", inspection.appliedModules.joined(separator: ", ")),
                appState.localizedFormat("누락된 모듈: %@", inspection.missingModules.joined(separator: ", ")),
                appState.localizedFormat("혼합된 모듈: %@", inspection.mixedModules.joined(separator: ", "))
            ].joined(separator: "\n")
        case .authenticateSteam:
            return appState.localized("검증 순서: 로그인 화면 → Steam Guard(필요 시) → 라이브러리 화면")
        case .connectLibrary:
            return appState.localized("스캔: SteamLibrary, steamapps, steamapps/common, appmanifest_*.acf")
        case .ready:
            return appState.localized("실패 시 Logs/Launch + Rule Engine 진단")
        }
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

    private var rendererPolicySetupActionTitleKey: String {
        if isApplyingRendererPolicy { return "실행 경로 정비 중" }
        return readiness.rendererInspection?.setupRecoveryActionTitleKey ?? "Steam 실행 경로 적용"
    }

    private var rendererPolicyActionTitleKey: String {
        if isApplyingRendererPolicy { return "실행 경로 정비 중" }
        return readiness.rendererInspection?.recoveryActionTitleKey ?? "실행 경로 적용/검증"
    }

    private var isRendererPolicyActionDisabled: Bool {
        if isApplyingRendererPolicy || services.steamPrefixLifecycleCoordinator.isBusy {
            return true
        }
        guard let inspection = readiness.rendererInspection else {
            return false
        }
        return !inspection.allowsRecoveryAction
    }

    private var steamReferenceRefreshActionTitleKey: String {
        services.isSteamReferenceRefreshInProgress ? "참고 목록 찾는 중" : "Steam 참고 목록 새로고침"
    }

    private func applyRendererPolicy() {
        guard !isApplyingRendererPolicy else {
            appState.setNotice(appState.localized("Steam 실행 경로 정비가 이미 진행 중입니다."), kind: .warning)
            return
        }
        if let inspection = readiness.rendererInspection,
           !inspection.allowsRecoveryAction {
            appState.setNotice(appState.localized(inspection.userMessage), kind: .failure)
            return
        }
        guard let runtimeExecutable = appState.runtimeExecutableURL else {
            appState.setNotice(appState.localized("Steam 실행 경로를 정비하려면 ForgePlay Runtime이 필요합니다."), kind: .warning)
            return
        }
        guard let prefix = readiness.steamPrefixURL, readiness.hasSteamPrefix else {
            appState.setNotice(appState.localized("Steam 실행 경로를 정비하려면 Steam 프리픽스를 먼저 만들어야 합니다."), kind: .warning)
            return
        }
        let rendererSelection = appState.steamRendererPolicySelection
        let videoMemorySelection = appState.steamVideoMemorySelection
        isApplyingRendererPolicy = true
        appState.setTask(appState.localized("Steam 클라이언트 호환 프로필과 게임 전용 renderer 프로세스 정책을 적용하는 중입니다."))
        Task {
            defer { isApplyingRendererPolicy = false }
            do {
                let inspection = try await services.steamPrefixService.applyRendererPolicy(
                    prefix: prefix,
                    runtimeExecutable: runtimeExecutable,
                    selection: rendererSelection,
                    videoMemorySelection: videoMemorySelection,
                    synchronizationSelection: appState.wineSynchronizationSelection
                )
                refreshProgress()
                let kind: AppNoticeKind = inspection.status == .ok ? .success : .failure
                appState.setNotice(
                    inspection.status == .ok
                        ? rendererPolicyAppliedMessage(for: inspection)
                        : appState.localized(inspection.userMessage),
                    kind: kind
                )
            } catch {
                appState.setError(error)
            }
        }
    }

    private func rendererPolicyAppliedMessage(for _: SteamRendererPolicyInspection) -> String {
        appState.localized("Steam 클라이언트 호환 프로필과 게임 렌더러 설정을 적용했습니다.")
    }

    private func requestSteamPrefixCreation() {
        if let bundledRuntimeUnavailableReason {
            appState.setNotice(bundledRuntimeUnavailableReason, kind: .warning)
            return
        }
        if let issue = readiness.rootIssue {
            appState.setNotice(appState.localizedError(issue), kind: .failure)
            appState.presentedSheet = .chooseRoot
            return
        }
        guard appState.selectedRootURL != nil else {
            appState.setNotice(appState.localized("앱 데이터 위치를 준비하지 못했습니다."), kind: .warning)
            appState.presentedSheet = .chooseRoot
            return
        }
        guard appState.runtimeExecutableURL != nil else {
            appState.setNotice(appState.localized("Steam 프리픽스를 만들려면 ForgePlay Runtime을 먼저 확인하세요."), kind: .warning)
            return
        }
        if let runtimeExecutable = appState.runtimeExecutableURL {
            do {
                _ = try services.windowsRuntimeService.validateWindowsSteamClientLaunchSupport(executable: runtimeExecutable)
            } catch {
                appState.setError(error)
                return
            }
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
        do {
            _ = try services.windowsRuntimeService.validateWindowsSteamClientLaunchSupport(executable: runtimeExecutable)
        } catch {
            appState.setError(error)
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
                refreshProgress()
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

    private func refreshSteamReferences(
        extraRoots: [URL] = [],
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
                let hasSteamReferences = scanResult.hasReferencesAfterScan(
                    existingCount: storageAccess.sourceGameRecordCount,
                    whenStorageAccessIsComplete: storageAccess.allowsRemovingStaleReferences
                )
                services.synchronizeSetupWorkflow(
                    appState: appState,
                    hasSteamReferences: hasSteamReferences,
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

    private func refreshProgress(hasSteamReferencesOverride: Bool? = nil) {
        services.synchronizeSetupWorkflow(
            appState: appState,
            hasSteamReferences: hasSteamReferencesOverride ?? !games.isEmpty,
            launchRecords: launchRecords
        )
    }

    private func refreshChecksAndProgress() async {
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

    private func clearTaskLater(_ noticeID: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(3))
            appState.clearNotice(id: noticeID)
        }
    }

    private func blockedReason(for stage: SetupStage) -> String? {
        switch stage {
        case .chooseRoot:
            return readiness.rootIssue.map { appState.localizedError($0) }
        case .checkMac:
            if let issue = readiness.rootIssue { return appState.localizedError(issue) }
            return appState.selectedRootURL == nil ? appState.localized("앱 데이터 위치를 준비하지 못했습니다.") : nil
        case .prepareEngine:
            if let issue = readiness.rootIssue { return appState.localizedError(issue) }
            if let bundledRuntimeUnavailableReasonKey { return bundledRuntimeUnavailableReasonKey }
            if let runtimeExecutable = appState.runtimeExecutableURL {
                do {
                    let verification = try services.steamPrefixService.inspectSteamClientCompatibility(runtimeExecutable)
                    if !verification.canLaunchWindowsSteam {
                        return verification.userMessage
                    }
                } catch {
                    return appState.localizedError(error)
                }
            }
            return appState.selectedRootURL == nil ? appState.localized("앱 데이터 위치를 준비하지 못했습니다.") : nil
        case .prepareSteamEnvironment:
            if let issue = readiness.rootIssue { return appState.localizedError(issue) }
            if let bundledRuntimeUnavailableReasonKey { return bundledRuntimeUnavailableReasonKey }
            if readiness.steamPrefixIssue != nil { return appState.localized("Steam 프리픽스를 다시 만들거나 저장 위치를 확인하세요.") }
            return appState.runtimeExecutableURL == nil ? appState.localized("ForgePlay Runtime을 먼저 확인하세요.") : nil
        case .installSteam:
            if let issue = readiness.rootIssue { return appState.localizedError(issue) }
            if let bundledRuntimeUnavailableReasonKey { return bundledRuntimeUnavailableReasonKey }
            if appState.runtimeExecutableURL == nil { return appState.localized("ForgePlay Runtime을 먼저 확인하세요.") }
            if readiness.steamPrefixIssue != nil { return appState.localized("Steam 프리픽스를 먼저 복구하세요.") }
            if !readiness.hasSteamPrefix { return appState.localized("먼저 Steam 프리픽스를 만드세요.") }
            return nil
        case .configureRenderer:
            if let issue = readiness.rootIssue { return appState.localizedError(issue) }
            if let bundledRuntimeUnavailableReasonKey { return bundledRuntimeUnavailableReasonKey }
            if appState.runtimeExecutableURL == nil { return appState.localized("ForgePlay Runtime을 먼저 확인하세요.") }
            if !readiness.hasSteamPrefix { return appState.localized("먼저 Steam 프리픽스를 만드세요.") }
            if !readiness.hasSteamExecutable { return appState.localized("먼저 Windows용 Steam을 설치하세요.") }
            if let inspection = readiness.rendererInspection,
               inspection.status == .error {
                return inspection.userMessage
            }
            return nil
        case .authenticateSteam:
            if let issue = readiness.rootIssue { return appState.localizedError(issue) }
            if appState.runtimeExecutableURL == nil { return appState.localized("ForgePlay Runtime을 먼저 확인하세요.") }
            if !readiness.hasSteamPrefix { return appState.localized("먼저 Steam 프리픽스를 만드세요.") }
            if !readiness.hasSteamExecutable { return appState.localized("먼저 Windows용 Steam을 설치하세요.") }
            if !readiness.canAttemptWindowsSteamLaunch {
                return readiness.localizedSteamPrefixStateBlocker(appState: appState)
            }
            return nil
        case .connectLibrary:
            if let issue = readiness.rootIssue { return appState.localizedError(issue) }
            return appState.selectedRootURL == nil ? appState.localized("앱 데이터 위치를 준비하지 못했습니다.") : nil
        case .ready:
            return nil
        }
    }
}

private struct SetupStepRow<Action: View>: View {
    var stage: SetupStage
    var state: SetupStepVisualState
    var detail: String
    var technicalHint: String
    var blockedReason: String?
    var isExpanded: Bool
    var toggleExpanded: () -> Void
    var action: () -> Action
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleExpanded) {
                HStack(alignment: .top, spacing: 14) {
                    rowIcon(palette: palette)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(appState.localized(stage.title))
                                .font(.headline)
                                .foregroundStyle(palette.text)
                                .fixedSize(horizontal: false, vertical: true)
                            StatusBadge(label: label(for: state), status: state.status)
                        }
                        if state == .current || state == .blocked {
                            Text(appState.localized(stage.beginnerDescription))
                                .font(.caption)
                                .foregroundStyle(palette.secondaryText)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 24, height: 24)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(ForgeActionButtonStyle(liftsOnHover: false))

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    AdaptiveDetailText(
                        text: detail,
                        font: .caption,
                        color: palette.secondaryText
                    )
                    if appState.isAdvancedModeEnabled {
                        AdaptiveDetailText(
                            text: technicalHint,
                            font: .system(.caption, design: .monospaced),
                            color: palette.secondaryText
                        )
                    }
                    blockedReasonText(palette: palette)
                    action()
                        .frame(minWidth: 150, idealWidth: 190, maxWidth: 260, alignment: .leading)
                }
                .padding(.leading, 48)
                .padding(.trailing, 8)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(state == .current ? palette.primary.opacity(0.06) : Color.clear)
        .clipShape(
            RoundedRectangle(
                cornerRadius: ForgePlayLayout.controlCornerRadius,
                style: .continuous
            )
        )
    }

    private func rowIcon(palette: ForgePlayPalette) -> some View {
        Image(systemName: state.symbolName)
            .font(.title3)
            .foregroundStyle(state.status.color(in: palette))
            .frame(width: 26)
            .padding(.top, 3)
    }

    @ViewBuilder
    private func blockedReasonText(palette: ForgePlayPalette) -> some View {
        if let blockedReason {
            Text(appState.localized(blockedReason))
                .font(.caption2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: 520, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(for state: SetupStepVisualState) -> String {
        switch state {
        case .complete: "완료"
        case .current: "현재 단계"
        case .blocked: "확인 필요"
        case .pending: "대기"
        }
    }
}

private enum NativeActionProminence {
    case primary
    case secondary
}

private struct NativeActionButton: View {
    var title: String
    var systemImage: String
    var prominence: NativeActionProminence
    var isDisabled = false
    var action: () -> Void

    @ViewBuilder
    var body: some View {
        switch prominence {
        case .primary:
            ThemedActionButton(
                title: title,
                systemImage: systemImage,
                prominence: .primary,
                isDisabled: isDisabled,
                action: action
            )
        case .secondary:
            ThemedActionButton(
                title: title,
                systemImage: systemImage,
                prominence: .secondary,
                isDisabled: isDisabled,
                action: action
            )
        }
    }
}
