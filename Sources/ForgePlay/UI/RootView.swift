import AppKit
import SwiftData
import SwiftUI

private enum RootChromeMetrics {
    static let detailHorizontalPadding: CGFloat = 28
    static let detailNoticeVerticalPadding: CGFloat = 10
    static let detailContentTopPadding: CGFloat = 20
    static let detailContentBottomPadding: CGFloat = 30
    static let sidebarContentTopPadding: CGFloat = 18
}

enum ForgePlayRootStartupEvent: Equatable {
    case succeeded
    case failed
    case requiresUserIntervention
}

enum ForgePlayRootStartupPresentation: Equatable {
    case loading
    case ready
    case recovery

    var showsBrandedLoading: Bool {
        self == .loading
    }

    func transitioned(for event: ForgePlayRootStartupEvent) -> Self {
        switch event {
        case .succeeded:
            .ready
        case .failed, .requiresUserIntervention:
            .recovery
        }
    }
}

enum ForgePlayRootSidebarNavigation {
    static let primarySections: [AppSection] = [
        .steamLaunch,
        .steamCompatibilityLaunch,
        .dashboard,
        .compatibilityCatalog,
        .windowsUtility,
        .diagnostics
    ]
}

enum ForgePlaySidebarCommunityAction: String, CaseIterable, Identifiable {
    case star
    case sponsor

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .star: "⭐ 좋아요"
        case .sponsor: "💗 후원하기"
        }
    }

    var helpKey: String {
        switch self {
        case .star: "GitHub 저장소에서 ForgePlay에 Star를 남깁니다."
        case .sponsor: "GitHub Sponsors에서 ForgePlay를 후원합니다."
        }
    }

    var url: URL? {
        switch self {
        case .star: ExternalLinkPolicy.forgePlayRepositoryStarURL
        case .sponsor: ExternalLinkPolicy.forgePlaySponsorsURL
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Query private var games: [SteamGameRecord]
    @Query private var launchRecords: [LaunchRecord]
    @State private var didLoad = false
    @State private var didAttemptStartupWorkflow = false
    @State private var isStartupInProgress = false
    @State private var automaticLogCleanupTask: Task<Void, Never>?
    @State private var startupResumeTask: Task<Void, Never>?
    @State private var startupPresentation: ForgePlayRootStartupPresentation = .loading
    @State private var ownsAutomaticSetupDestination = false

    init() {
        // Startup readiness only needs existence, not the complete Steam
        // reference catalog. Avoid materializing a large library before the
        // first Steam-launch screen can appear.
        var gameDescriptor = FetchDescriptor<SteamGameRecord>()
        gameDescriptor.fetchLimit = 1
        _games = Query(gameDescriptor)
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

    var body: some View {
        @Bindable var appState = appState
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        startupContent(palette: palette)
        .preferredColorScheme(appState.themeMode.preferredColorScheme)
        .tint(palette.primary)
        .background(palette.background.ignoresSafeArea())
        .environment(\.locale, appState.locale)
        .sheet(item: $appState.presentedSheet) { destination in
            SheetHostView(destination: destination)
                .environment(appState)
                .environment(services)
                .environment(\.locale, appState.locale)
        }
        .task {
            await runStartupWorkflow()
        }
        .onChange(of: isRootSheetPresented) { previous, current in
            guard previous, !current, !didLoad else { return }
            startupResumeTask?.cancel()
            startupResumeTask = Task { await resumeStartupAfterRootSheet() }
        }
        .onChange(of: setupReadinessObservationKey) { _, _ in
            refreshSetupStage()
        }
        .onChange(of: appState.setupReadiness) { previousReadiness, readiness in
            applyLaunchabilityTransition(
                previousReadiness: previousReadiness,
                readiness: readiness
            )
        }
        .onChange(of: appState.selectedSection) { _, section in
            if section != .setup {
                ownsAutomaticSetupDestination = false
            }
        }
        .onChange(of: appState.gameInputProtectionSettingsFingerprint) { _, _ in
            services.synchronizeGameInputProtectionPolicy(from: appState)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            services.refreshGameInputProtectionAuthorizationStatus()
            services.notifySteamEnvironmentChanged()
            refreshSetupStage()
        }
        .onDisappear {
            automaticLogCleanupTask?.cancel()
            startupResumeTask?.cancel()
        }
    }

    @ViewBuilder
    private func startupContent(palette: ForgePlayPalette) -> some View {
        if startupPresentation.showsBrandedLoading {
            ForgePlayLaunchSplashView()
        } else {
            GeometryReader { geometry in
                NavigationSplitView {
                    SidebarView(
                        selection: Binding(
                            get: { appState.selectedSection },
                            set: { section in
                                ownsAutomaticSetupDestination = false
                                appState.selectedSection = section
                            }
                        )
                    )
                        .navigationSplitViewColumnWidth(min: 216, ideal: 242, max: 268)
                } detail: {
                    RootDetailColumn(
                        notice: appState.currentNotice
                    ) {
                        content
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .background(palette.background.ignoresSafeArea())
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appState.selectedSection {
        case .dashboard:
            DashboardView()
        case .setup:
            SetupView(performsInitialWorkflowRefresh: false)
        case .steamLaunch:
            SteamLaunchView()
        case .steamCompatibilityLaunch:
            SteamCompatibilityLaunchView { context in
                SteamManagerCompatibilityLaunchRuntimeProviderV1(
                    steamPrefixService: services.steamPrefixService,
                    steamManager: services.steamManager,
                    windowsRuntimeService: services.windowsRuntimeService,
                    context: context
                )
            }
        case .compatibilityCatalog:
            CompatibilityCatalogView()
        case .windowsUtility:
            WindowsUtilityLaunchView()
        case .diagnostics:
            DiagnosticsView()
        case .learnAboutForgePlay:
            ForgePlayOverviewView()
        case .hallOfSupporters:
            HallOfSupportersView()
        case .developerApps:
            DeveloperAppsView()
        case .settings:
            SettingsView(performsInitialWorkflowRefresh: false)
        case .advanced:
            AdvancedView()
        }
    }

    private func refreshSetupStage() {
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

    private var setupReadinessObservationKey: SetupReadinessObservationKey? {
        _ = launchRecords.first?.id
        return try? services.setupReadinessObservationKey(
            appState: appState,
            in: modelContext,
            hasSteamReferences: !games.isEmpty
        )
    }

    private var isRootSheetPresented: Bool {
        if case .chooseRoot? = appState.presentedSheet {
            return true
        }
        return false
    }

    private func runStartupWorkflow() async {
        guard !didLoad, !didAttemptStartupWorkflow, !isStartupInProgress else { return }
        didAttemptStartupWorkflow = true
        isStartupInProgress = true
        defer { isStartupInProgress = false }

        while true {
            do {
                try Task.checkCancellation()
                let workflow = try await services.refreshSetupWorkflow(
                    appState: appState,
                    in: modelContext,
                    hasSteamReferences: !games.isEmpty
                )
                try Task.checkCancellation()
                try await finalizeStartup(workflow: workflow)
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
                handleStartupFailure(error)
                return
            }
        }
    }

    private func resumeStartupAfterRootSheet() async {
        guard !didLoad, !isStartupInProgress else { return }
        // Dismissing a recovery sheet is not a retry request. Retrying here
        // immediately reproduced the same failure and reopened the sheet,
        // trapping the user in a modal loop. Successful sheet actions place
        // storage in `.ready` before dismissing and may resume startup below.
        guard case .ready = services.managedStoragePreparationState else { return }

        isStartupInProgress = true
        defer { isStartupInProgress = false }
        do {
            try Task.checkCancellation()
            try await finalizeStartup(workflow: nil)
        } catch is CancellationError {
            return
        } catch {
            handleStartupFailure(error)
        }
    }

    private func finalizeStartup(workflow: SetupWorkflowRefreshResult?) async throws {
        try Task.checkCancellation()
        try appState.loadIfNeeded(from: modelContext)
        services.synchronizeGameInputProtectionPolicy(from: appState)
        try Task.checkCancellation()
        if appState.isLogAutoCleanupEnabled {
            scheduleAutomaticLogCleanup(
                retentionDays: appState.logRetentionDays,
                launchLogLimit: appState.launchLogLimit
            )
        }
        if let workflow {
            let cleanupWarning = workflow.storageActivation.sourceCleanupWarning.map {
                appState.localizedFormat(
                    "이전 위치의 관리 데이터 일부를 정리하지 못했습니다: %@",
                    $0
                )
            }
            let postCommitWarning = workflow.storageActivation.postCommitWarning.map {
                appState.localizedFormat(
                    "앱 데이터 위치는 적용됐지만 화면 상태 또는 실행 기록을 완전히 새로 고치지 못했습니다: %@",
                    $0
                )
            }
            let migrationMessage = workflow.storageActivation.didMigrateLegacyData
                ? appState.localizedFormat(
                    "기존 프리픽스를 내부 저장소로 옮겼습니다: %d개 항목, %@. 외장 게임 라이브러리는 원래 위치를 유지합니다.",
                    workflow.storageActivation.copiedFiles,
                    appState.localizedByteCount(workflow.storageActivation.copiedBytes)
                )
                : nil
            if let message = DiagnosticWarningText.combined(
                migrationMessage,
                cleanupWarning,
                postCommitWarning
            ) {
                appState.setNotice(
                    message,
                    kind: cleanupWarning == nil && postCommitWarning == nil ? .success : .warning
                )
            }
        }
        let currentDestination = appState.selectedSection
        let startupDestination = AppStartupDestinationResolver.resolve(
            current: currentDestination,
            readiness: appState.setupReadiness
        )
        ownsAutomaticSetupDestination = currentDestination == .dashboard &&
            startupDestination == .setup
        appState.selectedSection = startupDestination
        didLoad = true
        startupPresentation = startupPresentation.transitioned(for: .succeeded)

        #if DEBUG
        appState.applyDebugLaunchOptionsIfNeeded()
        activateWindowForDebugCaptureIfNeeded()
        await appState.applyDebugPostLaunchActionsIfNeeded(saveTo: modelContext)
        if appState.debugAppStoreScreenshotFixture {
            try? await Task.sleep(for: .milliseconds(300))
            resizeAppStoreScreenshotWindowIfNeeded()
        }
        #endif
    }

    private func handleStartupFailure(_ error: Error) {
        if case ManagedStorageActivationError.legacyMigrationDecisionRequired = error {
            appState.setNotice(appState.localizedError(error), kind: .warning)
        } else {
            appState.setError(error)
        }
        let requiresManagedStorageIntervention: Bool
        if let activationError = error as? ManagedStorageActivationError,
           activationError.requiresUserIntervention {
            requiresManagedStorageIntervention = true
        } else {
            requiresManagedStorageIntervention = false
        }
        if requiresManagedStorageIntervention {
            appState.setupStage = .chooseRoot
            ownsAutomaticSetupDestination = true
            appState.selectedSection = .setup
        } else {
            let readiness = (try? services.synchronizeSetupWorkflow(
                appState: appState,
                in: modelContext,
                hasSteamReferences: !games.isEmpty
            )) ?? appState.setupReadiness
            let currentDestination = appState.selectedSection
            let recoveryDestination = AppStartupDestinationResolver.resolve(
                current: currentDestination,
                readiness: readiness
            )
            ownsAutomaticSetupDestination = currentDestination == .dashboard &&
                recoveryDestination == .setup
            appState.selectedSection = recoveryDestination
            didLoad = true
        }
        startupPresentation = startupPresentation.transitioned(
            for: requiresManagedStorageIntervention ? .requiresUserIntervention : .failed
        )
        if requiresManagedStorageIntervention {
            appState.presentedSheet = .chooseRoot
        }
    }

    private func applyLaunchabilityTransition(
        previousReadiness: SetupReadiness,
        readiness: SetupReadiness
    ) {
        let destination = AppStartupDestinationResolver.resolveLaunchabilityTransition(
            current: appState.selectedSection,
            previousReadiness: previousReadiness,
            readiness: readiness,
            ownsAutomaticSetupDestination: ownsAutomaticSetupDestination
        )
        guard destination != appState.selectedSection else { return }
        ownsAutomaticSetupDestination = false
        appState.selectedSection = destination
    }

    private func scheduleAutomaticLogCleanup(retentionDays: Int, launchLogLimit: Int) {
        do {
            let cleanupTask = try services.logRetentionService.cleanupInBackground(
                retentionDays: retentionDays,
                launchLogLimit: launchLogLimit
            )
            automaticLogCleanupTask?.cancel()
            automaticLogCleanupTask = Task {
                await withTaskCancellationHandler {
                    do {
                        _ = try await cleanupTask.value
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled else { return }
                        appState.setNotice(
                            appState.localizedFormat(
                                "자동 로그 정리에 실패했습니다: %@",
                                appState.localizedError(error)
                            ),
                            kind: .warning
                        )
                    }
                } onCancel: {
                    cleanupTask.cancel()
                }
            }
        } catch LogRetentionServiceError.cleanupInProgress {
            // A manual cleanup or an earlier startup pass already owns this
            // filesystem mutation. Do not surface an expected single-flight
            // collision as a startup warning.
            return
        } catch {
            appState.setNotice(
                appState.localizedFormat("자동 로그 정리를 시작하지 못했습니다: %@", appState.localizedError(error)),
                kind: .warning
            )
        }
    }

    #if DEBUG
    private func activateWindowForDebugCaptureIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        let arguments = ProcessInfo.processInfo.arguments.joined(separator: " ")
        let shouldActivate = environment.keys.contains {
            $0.hasPrefix("FORGEPLAY_QA_") || $0 == "FORGEPLAY_APP_STORE_SCREENSHOT_FIXTURE"
        } || arguments.contains("--FORGEPLAY_QA_") || arguments.contains("--FORGEPLAY_APP_STORE_SCREENSHOT_FIXTURE")
        guard shouldActivate else { return }

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
    }

    private func resizeAppStoreScreenshotWindowIfNeeded() {
        guard appState.debugAppStoreScreenshotFixture else { return }
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }) else { return }

        let targetSize = NSSize(width: 1440, height: 900)
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let origin = if let visibleFrame {
            NSPoint(
                x: visibleFrame.midX - targetSize.width / 2,
                y: visibleFrame.midY - targetSize.height / 2
            )
        } else {
            NSPoint(x: 40, y: 40)
        }
        window.setFrame(NSRect(origin: origin, size: targetSize), display: true)
    }
    #endif
}

private struct RootDetailColumn<Content: View>: View {
    var notice: AppNotice?
    @ViewBuilder var content: () -> Content
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 0) {
            if let notice {
                TaskBanner(notice: notice)
                    .padding(.horizontal, RootChromeMetrics.detailHorizontalPadding)
                    .padding(.vertical, RootChromeMetrics.detailNoticeVerticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GeometryReader { geometry in
                let contentWidth = max(
                    geometry.size.width - (RootChromeMetrics.detailHorizontalPadding * 2),
                    0
                )
                let contentHeight = max(
                    geometry.size.height - RootChromeMetrics.detailContentTopPadding - RootChromeMetrics.detailContentBottomPadding,
                    0
                )
                content()
                    .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
                    .padding(.horizontal, RootChromeMetrics.detailHorizontalPadding)
                    .padding(.top, RootChromeMetrics.detailContentTopPadding)
                    .padding(.bottom, RootChromeMetrics.detailContentBottomPadding)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.background.ignoresSafeArea())
    }
}

private struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: AppSection
    @State private var updateCheckTask: Task<Void, Never>?
    @State private var updateCheckPresentation: ManualUpdateCheckPresentation = .idle
    @State private var availableUpdateReleaseURL: URL?
    @State private var hoveredCommunityAction: ForgePlaySidebarCommunityAction?

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ForgePlay")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(palette.text)
                        .lineLimit(nil)
                    Text(appState.localized("Windows 게임을 Mac에서 더 쉽게."))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, RootChromeMetrics.sidebarContentTopPadding)

            List(selection: $selection) {
                Section {
                    ForEach(ForgePlayRootSidebarNavigation.primarySections) { section in
                        sidebarRow(section)
                    }
                }

                Section {
                    sidebarRow(.settings)
                    if appState.isAdvancedModeEnabled {
                        sidebarRow(.advanced)
                    }
                }

                Section {
                    sidebarRow(.learnAboutForgePlay)
                    sidebarRow(.hallOfSupporters)
                    sidebarRow(.developerApps)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    selection = .setup
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: sidebarStatusSymbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                appState.systemCheckSummary.displayStatus.color(in: palette)
                            )
                            .frame(width: 18, height: 18)
                        Text(appState.localized(systemStatusLabel))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.secondaryText)
                            .padding(.top, 3)
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ForgeActionButtonStyle(liftsOnHover: false))
                .background(palette.control.opacity(0.62))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: ForgePlayLayout.controlCornerRadius,
                        style: .continuous
                    )
                )
                .help(appState.localized("설정 열기"))

                HStack(spacing: 8) {
                    ForEach(ForgePlaySidebarCommunityAction.allCases) { action in
                        sidebarCommunityButton(action, palette: palette)
                    }
                }

                Group {
                    if let hoveredCommunityAction {
                        Label(
                            appState.localized(hoveredCommunityAction.helpKey),
                            systemImage: "info.circle.fill"
                        )
                        .transition(.opacity)
                    } else {
                        Text(" ")
                            .accessibilityHidden(true)
                    }
                }
                .font(.caption2)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                .padding(.horizontal, 4)
                .animation(.easeOut(duration: 0.12), value: hoveredCommunityAction)

                HStack(spacing: 8) {
                    Text(AppBuildInfo.displayVersion)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(palette.secondaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)

                Button {
                    if let availableUpdateReleaseURL {
                        appState.openExternalURL(availableUpdateReleaseURL)
                    } else {
                        checkForUpdate()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(
                            systemName: updateCheckPresentation == .checking
                                ? "arrow.triangle.2.circlepath"
                                : "checkmark.arrow.trianglehead.counterclockwise"
                        )
                            .frame(width: 18)
                        Text(appState.localized(updateCheckPresentation.labelKey))
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ForgeActionButtonStyle(liftsOnHover: false))
                .background(palette.control.opacity(0.62))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: ForgePlayLayout.controlCornerRadius,
                        style: .continuous
                    )
                )
                .disabled(updateCheckPresentation == .checking)
                .help(
                    appState.localized(
                        "ForgePlay 홈페이지의 공개 릴리스 정보를 확인합니다."
                    )
                )
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.sidebar.ignoresSafeArea())
        .tint(palette.primary)
        .onChange(of: appState.isAdvancedModeEnabled) { _, isEnabled in
            if !isEnabled, selection == .advanced {
                selection = .settings
            }
        }
        .onDisappear {
            updateCheckTask?.cancel()
            updateCheckTask = nil
            if updateCheckPresentation == .checking {
                updateCheckPresentation = .idle
            }
        }
    }

    private func sidebarCommunityButton(
        _ action: ForgePlaySidebarCommunityAction,
        palette: ForgePlayPalette
    ) -> some View {
        Button {
            appState.openExternalURL(action.url)
        } label: {
            Text(appState.localized(action.titleKey))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(ForgeActionButtonStyle(liftsOnHover: true))
        .background(
            hoveredCommunityAction == action
                ? palette.primary.opacity(0.15)
                : palette.control.opacity(0.62)
        )
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
            .stroke(
                hoveredCommunityAction == action
                    ? palette.primary.opacity(0.72)
                    : Color.clear,
                lineWidth: 1
            )
        }
        .onHover { isHovering in
            if isHovering {
                hoveredCommunityAction = action
            } else if hoveredCommunityAction == action {
                hoveredCommunityAction = nil
            }
        }
        .disabled(action.url == nil)
        .help(appState.localized(action.helpKey))
        .accessibilityHint(appState.localized(action.helpKey))
    }

    private func checkForUpdate() {
        guard updateCheckPresentation != .checking else { return }
        updateCheckTask?.cancel()
        availableUpdateReleaseURL = nil
        updateCheckPresentation = .checking
        updateCheckTask = Task { @MainActor in
            let result = await AppUpdateService().checkForUpdate()
            guard !Task.isCancelled else { return }
            switch result {
            case .updateRequired(let manifest):
                availableUpdateReleaseURL = manifest.releaseURL
                updateCheckPresentation = .updateRequired
            case .noUpdate:
                availableUpdateReleaseURL = nil
                updateCheckPresentation = .noUpdate
            case .failure(let error):
                availableUpdateReleaseURL = nil
                updateCheckPresentation = .failure
                appState.setNotice(
                    appState.localizedError(error),
                    kind: .warning,
                    captureFailureEvidence: false
                )
            }
        }
    }

    private func sidebarRow(_ section: AppSection) -> some View {
        Label {
            Text(appState.localized(section.title))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: section.symbolName)
                .frame(width: 19)
        }
        .font(.callout.weight(selection == section ? .semibold : .regular))
        .padding(.vertical, 5)
        .tag(section)
    }

    private var systemStatusLabel: String {
        switch appState.systemCheckSummary.phase {
        case .unverified: "시스템 확인 필요"
        case .blocked: "설정 문제 있음"
        case .readyWithWarnings: "시스템 준비됨 · 확인 필요"
        case .ready: "시스템 준비 완료"
        }
    }

    private var sidebarStatusSymbol: String {
        switch appState.systemCheckSummary.displayStatus {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .unknown: "minus.circle.fill"
        }
    }
}

private enum ManualUpdateCheckPresentation: Equatable {
    case idle
    case checking
    case noUpdate
    case updateRequired
    case failure

    var labelKey: String {
        switch self {
        case .idle: "업데이트 확인 (베타)"
        case .checking: "업데이트 확인 중"
        case .noUpdate: "업데이트 없음"
        case .updateRequired: "업데이트 필요"
        case .failure: "업데이트 확인 실패"
        }
    }
}

enum AppBuildInfo {
    static var displayVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return displayVersion(version: version, build: build)
    }

    static func displayVersion(version: String?, build: String?) -> String {
        let cleanVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBuild = build?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let cleanVersion, !cleanVersion.isEmpty,
           let cleanBuild, !cleanBuild.isEmpty {
            return "ForgePlay \(cleanVersion) (\(cleanBuild))"
        }
        if let cleanVersion, !cleanVersion.isEmpty {
            return "ForgePlay \(cleanVersion)"
        }
        return "ForgePlay"
    }
}

struct TaskBanner: View {
    var notice: AppNotice
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
        let statusColor = notice.kind.status.color(in: palette)

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                bannerLeadingContent(statusColor: statusColor)
                Spacer(minLength: 12)
                bannerActions
            }
            VStack(alignment: .leading, spacing: 10) {
                bannerLeadingContent(statusColor: statusColor)
                bannerActions
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 1_000)
        .foregroundStyle(palette.text)
        .background(palette.surfaceElevated)
        .clipShape(
            RoundedRectangle(
                cornerRadius: ForgePlayLayout.panelCornerRadius,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: ForgePlayLayout.panelCornerRadius,
                style: .continuous
            )
                .stroke(statusColor.opacity(0.28), lineWidth: 1)
        )
    }

    private func bannerLeadingContent(statusColor: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if notice.kind == .progress {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
            } else {
                Image(systemName: notice.kind.symbolName)
                    .foregroundStyle(statusColor)
                    .padding(.top, 2)
            }

            Text(notice.message)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }

    private var bannerActions: some View {
        ResponsiveActionRow(spacing: 8) {
            if let logURL = notice.logURL {
                ThemedActionButton(
                    title: "로그 보기",
                    systemImage: "doc.text.magnifyingglass",
                    prominence: .secondary,
                    controlSize: .small
                ) {
                    appState.revealInFinder(logURL)
                }
                .frame(minWidth: 112, idealWidth: 132, maxWidth: 180)
            }

            Button {
                appState.clearNotice()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ForgeActionButtonStyle(liftsOnHover: false))
            .controlSize(.small)
            .help(appState.localized("닫기"))
        }
    }
}
