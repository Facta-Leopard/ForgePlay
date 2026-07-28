import AppKit
import SwiftData
import SwiftUI

private enum RootChromeMetrics {
    static let detailHorizontalPadding: CGFloat = 28
    static let detailToolbarTopPadding: CGFloat = 10
    static let detailToolbarBottomPadding: CGFloat = 10
    static let detailContentTopPadding: CGFloat = 20
    static let detailContentBottomPadding: CGFloat = 30
    static let sidebarContentTopPadding: CGFloat = 18
}

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \SteamGameRecord.name) private var games: [SteamGameRecord]
    @Query(sort: \LaunchRecord.startedAt, order: .reverse) private var launchRecords: [LaunchRecord]
    @State private var didLoad = false
    @State private var isStartupInProgress = false
    @State private var automaticLogCleanupTask: Task<Void, Never>?

    var body: some View {
        @Bindable var appState = appState
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        GeometryReader { geometry in
            NavigationSplitView {
                SidebarView(selection: $appState.selectedSection)
                    .navigationSplitViewColumnWidth(min: 216, ideal: 242, max: 268)
            } detail: {
                RootDetailColumn(
                    notice: appState.currentNotice,
                    openLogsFolder: openLogsFolder,
                    openSettings: { appState.selectedSection = .settings }
                ) {
                    content
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(palette.background.ignoresSafeArea())
        }
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
            Task { await resumeStartupAfterRootSheet() }
        }
        .onChange(of: games.count) { _, _ in
            refreshSetupStage()
        }
        .onChange(of: SteamLaunchRecordLookup.stateFingerprint(from: launchRecords)) { _, _ in
            refreshSetupStage()
        }
        .onChange(of: services.steamEnvironmentRevision) { _, _ in
            refreshSetupStage()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            services.notifySteamEnvironmentChanged()
            refreshSetupStage()
        }
        .onDisappear {
            automaticLogCleanupTask?.cancel()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appState.selectedSection {
        case .dashboard:
            DashboardView()
        case .setup:
            SetupView()
        case .steamLaunch:
            SteamLaunchView()
        case .diagnostics:
            DiagnosticsView()
        case .hallOfSupporters:
            HallOfSupportersView()
        case .developerApps:
            DeveloperAppsView()
        case .settings:
            SettingsView()
        case .advanced:
            AdvancedView()
        }
    }

    private func refreshSetupStage() {
        services.synchronizeSetupWorkflow(
            appState: appState,
            hasSteamReferences: !games.isEmpty,
            launchRecords: launchRecords
        )
    }

    private var isRootSheetPresented: Bool {
        if case .chooseRoot? = appState.presentedSheet {
            return true
        }
        return false
    }

    private func runStartupWorkflow() async {
        guard !didLoad, !isStartupInProgress else { return }
        isStartupInProgress = true
        defer { isStartupInProgress = false }

        do {
            let workflow = try await services.refreshSetupWorkflow(
                appState: appState,
                in: modelContext,
                hasSteamReferences: !games.isEmpty,
                launchRecords: launchRecords
            )
            try await finalizeStartup(workflow: workflow)
        } catch {
            handleStartupFailure(error)
            return
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
            try await finalizeStartup(workflow: nil)
        } catch {
            handleStartupFailure(error)
        }
    }

    private func finalizeStartup(workflow: SetupWorkflowRefreshResult?) async throws {
        try appState.loadIfNeeded(from: modelContext)
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
        didLoad = true

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
        appState.setupStage = .chooseRoot
        appState.selectedSection = .setup
        if requiresManagedStorageIntervention {
            appState.presentedSheet = .chooseRoot
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

    private func scheduleAutomaticLogCleanup(retentionDays: Int, launchLogLimit: Int) {
        do {
            let cleanupTask = try services.logRetentionService.cleanupInBackground(
                retentionDays: retentionDays,
                launchLogLimit: launchLogLimit
            )
            automaticLogCleanupTask?.cancel()
            automaticLogCleanupTask = Task {
                do {
                    _ = try await cleanupTask.value
                } catch is CancellationError {
                    return
                } catch {
                    appState.setNotice(
                        appState.localizedFormat("자동 로그 정리에 실패했습니다: %@", appState.localizedError(error)),
                        kind: .warning
                    )
                }
            }
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
    var openLogsFolder: () -> Void
    var openSettings: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 0) {
            RootTopBar(
                openLogsFolder: openLogsFolder,
                openSettings: openSettings
            )
            if let notice {
                TaskBanner(notice: notice)
                    .padding(.horizontal, RootChromeMetrics.detailHorizontalPadding)
                    .padding(.bottom, RootChromeMetrics.detailToolbarBottomPadding)
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

private struct RootTopBar: View {
    var openLogsFolder: () -> Void
    var openSettings: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        HStack(spacing: 12) {
            Spacer(minLength: 20)

            HStack(spacing: 6) {
                RootChromeButton(
                    title: "문제 분석 기록(Log) 폴더",
                    systemImage: "folder",
                    action: openLogsFolder
                )
                RootChromeButton(
                    title: "설정",
                    systemImage: "gearshape",
                    action: openSettings
                )
            }
        }
        .padding(.horizontal, RootChromeMetrics.detailHorizontalPadding)
        .padding(.top, RootChromeMetrics.detailToolbarTopPadding)
        .padding(.bottom, RootChromeMetrics.detailToolbarBottomPadding)
        .frame(maxWidth: .infinity)
        .background(palette.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.separator)
                .frame(height: 1)
        }
    }
}

private struct RootChromeButton: View {
    var title: String
    var systemImage: String
    var action: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.secondaryText)
                .frame(width: 36, height: 34)
                .background(palette.control)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: ForgePlayLayout.controlCornerRadius,
                        style: .continuous
                    )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(ForgeActionButtonStyle(liftsOnHover: false))
        .help(appState.localized(title))
        .accessibilityLabel(appState.localized(title))
    }
}

private struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: AppSection

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
                    ForEach([AppSection.dashboard, .setup, .steamLaunch, .diagnostics]) { section in
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
                    sidebarRow(.hallOfSupporters)
                    sidebarRow(.developerApps)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Spacer()
            Button {
                selection = .setup
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: sidebarStatusSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appState.systemCheckSummary.displayStatus.color(in: palette))
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.localized(systemStatusLabel))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(AppBuildInfo.displayVersion)
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryText)
                    }
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
            .clipShape(RoundedRectangle(cornerRadius: ForgePlayLayout.controlCornerRadius, style: .continuous))
            .help(appState.localized("처음 설정 열기"))
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

private enum AppBuildInfo {
    static var displayVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
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
