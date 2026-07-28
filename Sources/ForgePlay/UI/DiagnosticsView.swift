import AppKit
import SwiftData
import SwiftUI

private enum DiagnosticEvidenceSelectionError: Error, ForgePlayUserFacingLocalizedError {
    case noLinkedEvidence(String)
    case noRecentEvidence

    @MainActor
    func localizedDescription(appState: AppState) -> String {
        switch self {
        case .noLinkedEvidence(let launchRecordIdentifier):
            appState.localizedFormat(
                "선택한 실행 기록에 연결된 로그 파일이 없습니다: %@",
                launchRecordIdentifier
            )
        case .noRecentEvidence:
            appState.localized("분석할 실행 로그가 아직 없습니다.")
        }
    }
}

struct DiagnosticsView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \DiagnosticRecord.createdAt, order: .reverse) private var records: [DiagnosticRecord]
    @Query(sort: \LaunchRecord.startedAt, order: .reverse) private var launchRecords: [LaunchRecord]
    @Query(sort: \SteamStorageMountRecord.path) private var steamStorageMounts: [SteamStorageMountRecord]
    @State private var aiPreview: LLMRequestSnapshot?
    @State private var aiPreviewEvidenceContext: DiagnosticEvidenceContext?
    @State private var selectedEvidenceLaunchRecordID: String?
    @State private var supportIncidentDraft: SupportIncidentDraft?
    @State private var isCreatingSupportBundle = false

    private struct DiagnosticEvidenceContext: Hashable {
        var gameID: String?
        var launchRecordID: String?
    }

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        ForgePageScaffold(
            "문제 진단",
            subtitle: "최근 실행 기록과 로그를 분석하고 필요한 조치를 확인합니다.",
            systemImage: "waveform.path.ecg.rectangle"
        ) {
            diagnosticsHeaderActions
        } content: {
            ForgeSection(
                PairedTerm.automaticAnalysis.displayName,
                subtitle: "로그는 먼저 로컬 규칙으로 분석하며, AI 분석은 미리보기 확인 후 실행합니다.",
                systemImage: "cpu"
            ) {
                diagnosticEvidenceSelector(palette: palette)
                ResponsiveActionRow {
                    SecondaryActionButton(title: "최근 로그 다시 분석", systemImage: "arrow.clockwise") {
                        runLocalAnalysis()
                    }
                    SecondaryActionButton(title: "AI 로컬 분석(베타) 전 미리보기", systemImage: "eye") {
                        prepareAIPreview()
                    }
                }
                .frame(maxWidth: 520)
                if let aiPreview {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(appState.localized("AI 로컬 분석(베타) 전 미리보기"))
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(appState.localizedFormat(
                            "가림 처리 %d건 · %@",
                            aiPreview.redactionPreview.replacementCount,
                            appState.localized(aiPreview.processingLocationKey)
                        ))
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(aiPreview.systemInstructions)
                                Divider()
                                Text(aiPreview.prompt)
                            }
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 160)
                        .padding(10)
                        .foregroundStyle(palette.text)
                        .background(palette.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        PrimaryActionButton(title: "이 내용으로 로컬 AI 진단(베타) 실행", systemImage: "brain") {
                            runAIDiagnostics()
                        }
                        .frame(maxWidth: 300)
                    }
                }
            }

            recentSteamLaunchRecordsCard(palette: palette)

            ForgeSection(
                "저장된 진단",
                subtitle: "최근 진단이 위에 표시됩니다.",
                systemImage: "doc.text.magnifyingglass"
            ) {
                ForEach(records) { record in
                    diagnosticRecordCard(record)
                }

                if records.isEmpty {
                    EmptyStateView(
                        systemImage: "doc.text",
                        title: "저장된 진단 없음",
                        message: "Steam 또는 게임 실행 실패 후 로그가 저장되면 이곳에 분석 결과가 나타납니다.",
                        fillsAvailableHeight: false
                    )
                    .frame(minHeight: 180)
                }
            }
        }
        .sheet(item: $supportIncidentDraft) { draft in
            SupportBundlePreparationView(
                initialDraft: draft,
                launchOptions: supportIncidentLaunchOptions,
                onCancel: { supportIncidentDraft = nil },
                onCreate: { completedDraft in
                    supportIncidentDraft = nil
                    createSupportBundle(incident: completedDraft.context)
                }
            )
        }
        #if DEBUG
        .task(id: appState.debugDiagnosticsPreviewFixture) {
            applyDebugAIPreviewFixtureIfNeeded()
        }
        #endif
        .onChange(of: selectedEvidenceLaunchRecordID) { _, _ in
            aiPreview = nil
            aiPreviewEvidenceContext = nil
        }
    }

    @ViewBuilder
    private func diagnosticEvidenceSelector(palette: ForgePlayPalette) -> some View {
        let candidates = Array(launchRecords.prefix(20))
        if candidates.isEmpty {
            Text(appState.localized("연결된 실행 기록이 없어 지원 번들을 제외한 최신 실행 로그만 분석합니다."))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
        } else {
            Picker(
                appState.localized("분석할 실행 기록"),
                selection: Binding(
                    get: { selectedEvidenceLaunchRecordID ?? diagnosticEvidenceLaunchRecord?.id },
                    set: { selectedEvidenceLaunchRecordID = $0 }
                )
            ) {
                ForEach(candidates) { record in
                    Text("\(record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.id.prefix(8))")
                        .tag(Optional(record.id))
                }
            }
            .pickerStyle(.menu)
            if let record = diagnosticEvidenceLaunchRecord {
                Text(appState.localizedFormat(
                    "분석 대상 실행 ID %@ · %@",
                    record.id,
                    record.startedAt.formatted(date: .abbreviated, time: .standard)
                ))
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.secondaryText)
                    .textSelection(.enabled)
            }
        }
    }

    private var recentSteamLaunchRecords: [LaunchRecord] {
        Array(launchRecords
            .filter { $0.commandKind == "launchSteam" && $0.prefixId == PrefixIdentifier.steamShared }
            .prefix(3))
    }

    private var diagnosticEvidenceLaunchRecord: LaunchRecord? {
        if let selectedEvidenceLaunchRecordID,
           let selected = launchRecords.first(where: { $0.id == selectedEvidenceLaunchRecordID }) {
            return selected
        }
        return launchRecords.first { record in
            record.status == "failed" ||
                record.steamUIVerificationState == .failed ||
                record.steamUIVerificationState == .blackScreenSuspected ||
                record.didTimeOut == true ||
                (record.exitCode.map { $0 != 0 } ?? false)
        } ?? launchRecords.first
    }

    private func recentSteamLaunchRecordsCard(palette: ForgePlayPalette) -> some View {
        ForgeCard("최근 Steam 실행 상태", systemImage: "play.circle") {
            VStack(alignment: .leading, spacing: 10) {
                Text(appState.localized("프로세스가 시작됐는지와 Windows용 Steam UI가 실제로 렌더링됐는지를 분리해서 표시합니다. 검은 화면이면 성공으로 보지 않습니다."))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if recentSteamLaunchRecords.isEmpty {
                    SteamLaunchRecordStatusPanel(record: nil)
                } else {
                    ForEach(recentSteamLaunchRecords) { record in
                        recentSteamLaunchRecordPanel(record)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recentSteamLaunchRecordPanel(_ record: LaunchRecord) -> some View {
        if steamLaunchRecordLifecycle.canConfirmSteamUI(for: record) {
            SteamLaunchRecordStatusPanel(
                record: record,
                showsEmptyState: false,
                onConfirmSurface: confirmSteamUISurface,
                onMarkBlackScreen: markSteamUIBlackScreen
            )
        } else {
            SteamLaunchRecordStatusPanel(
                record: record,
                showsEmptyState: false
            )
        }
    }

    private var supportBundleButton: some View {
        ThemedActionButton(
            title: isCreatingSupportBundle ? "지원 번들 생성 중" : "지원 번들 생성",
            systemImage: "doc.zipper",
            prominence: .secondary,
            isDisabled: isCreatingSupportBundle,
            controlSize: .small
        ) {
            prepareSupportBundle()
        }
        .frame(minWidth: 144, idealWidth: 170, maxWidth: 220)
    }

    private var failureEvidenceFolderButton: some View {
        ThemedActionButton(
            title: "실패 로그·Mac 사양 폴더 열기",
            systemImage: "folder",
            prominence: .secondary,
            controlSize: .small
        ) {
            openFailureEvidenceFolder()
        }
        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
        .help(appState.localized(
            "원본 로그에는 로컬 경로가 포함될 수 있습니다. 공유할 때는 개인정보를 가린 지원 번들을 생성하세요."
        ))
    }

    private var diagnosticsHeaderActions: some View {
        ResponsiveActionRow(alignment: .trailing, spacing: 8) {
            SectionHelpButton(section: .diagnostics)
            failureEvidenceFolderButton
            supportBundleButton
        }
    }

    private func openFailureEvidenceFolder() {
        if let evidenceURL = appState.lastFailureEvidenceURL,
           FileSystemItemPolicy.isRegularNonSymlinkFile(evidenceURL),
           appState.revealInFinder(evidenceURL) {
            return
        }

        if let evidenceDirectory = appState.lastFailureEvidenceURL?.deletingLastPathComponent(),
           FileSystemItemPolicy.isNonSymlinkDirectory(evidenceDirectory),
           appState.openFileURL(evidenceDirectory) {
            return
        }

        let emergencyDirectory = FailureDiagnosticEvidenceService.defaultEmergencyDiagnosticDirectory(
            fileManager: .default
        )
        if FileSystemItemPolicy.isNonSymlinkDirectory(emergencyDirectory),
           (try? FileManager.default.contentsOfDirectory(
            at: emergencyDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
           ).contains(where: { $0.lastPathComponent.hasPrefix("failure-") })) == true {
            _ = appState.openFileURL(emergencyDirectory)
            return
        }

        do {
            let logsRoot = try services.pathManager.url(for: .logs)
            guard FileSystemItemPolicy.isNonSymlinkDirectory(logsRoot) else {
                throw FailureDiagnosticEvidenceServiceError.unsafeDiagnosticDirectory(logsRoot)
            }
            _ = appState.openFileURL(logsRoot)
        } catch {
            appState.setError(error)
        }
    }

    private func runLocalAnalysis() {
        do {
            let evidence = try recentLogEvidence()
            let result = services.ruleEngine.analyze(logText: evidence.text)
            try save(
                results: result,
                source: .ruleEngine,
                evidenceContext: evidence.context
            )
            try modelContext.saveOrRollback()
            let notice = evidence.readError.map {
                appState.setNotice(forgePlayTechnicalErrorSummary($0), kind: .warning)
            } ?? appState.setNotice(appState.localized("최근 로그 분석을 저장했습니다."), kind: .success)
            clearTaskLater(notice.id)
        } catch {
            appState.setError(error)
        }
    }

    private func prepareAIPreview() {
        do {
            let settings = try appState.loadOrCreateSettings(in: modelContext)
            let evidence = try recentLogEvidence()
            let game = appState.selectedSteamReference?.game
            let language = appState.effectiveLanguageMode
            aiPreview = try services.llmService.preparePreview(
                logText: evidence.text,
                settings: settings,
                game: game,
                language: language,
                sensitivePaths: aiDiagnosticSensitivePaths(),
                sensitiveTerms: aiDiagnosticSensitiveTerms()
            )
            aiPreviewEvidenceContext = evidence.context
            if let readError = evidence.readError {
                appState.setNotice(forgePlayTechnicalErrorSummary(readError), kind: .warning)
            }
        } catch {
            appState.setError(error)
        }
    }

    private func runAIDiagnostics() {
        guard let snapshot = aiPreview else { return }
        do {
            let settings = try appState.loadOrCreateSettings(in: modelContext)
            appState.setTask(appState.localized("Apple Foundation Models로 AI 문제 진단을 실행하는 중입니다."))
            Task {
                do {
                    let result = try await services.llmService.diagnose(
                        snapshot: snapshot,
                        settings: settings
                    )
                    try save(
                        results: [result],
                        source: .appleFoundationModels,
                        evidenceContext: aiPreviewEvidenceContext ?? DiagnosticEvidenceContext(
                            gameID: appState.selectedSteamReference?.steamAppId,
                            launchRecordID: nil
                        )
                    )
                    try modelContext.saveOrRollback()
                    aiPreview = nil
                    aiPreviewEvidenceContext = nil
                    let notice = appState.setNotice(appState.localized("AI 문제 진단 결과를 저장했습니다."), kind: .success)
                    clearTaskLater(notice.id)
                } catch {
                    appState.setError(error)
                }
            }
        } catch {
            appState.setError(error)
        }
    }

    private var supportIncidentLaunchOptions: [SupportIncidentLaunchOption] {
        launchRecords.prefix(20).map(SupportIncidentLaunchOption.init)
    }

    private var defaultSupportIncidentLaunchRecord: LaunchRecord? {
        launchRecords.first { record in
            record.status == "failed" ||
                record.steamUIVerificationState == .failed ||
                record.steamUIVerificationState == .blackScreenSuspected ||
                record.didTimeOut == true ||
                (record.exitCode.map { $0 != 0 } ?? false)
        } ?? launchRecords.first
    }

    private func prepareSupportBundle() {
        guard !isCreatingSupportBundle else { return }
        supportIncidentDraft = SupportIncidentDraft(record: defaultSupportIncidentLaunchRecord)
    }

    private func createSupportBundle(incident: SupportIncidentContext) {
        guard !isCreatingSupportBundle else { return }
        isCreatingSupportBundle = true
        let progressNotice = appState.setTask(appState.localized("지원 번들을 만드는 중입니다."))
        let decoded = decodedDiagnosticsForSupportBundle()
        let steamStoragePaths = Array(Set(steamStorageMounts.map(\.path))).sorted()
        let synchronizationSelection = appState.wineSynchronizationSelection
        let rendererSelection = appState.steamRendererPolicySelection
        let videoMemorySelection = appState.steamVideoMemorySelection
        let supportBundleLaunchRecords = Array(launchRecords)
        let systemChecks = appState.latestChecks
        let selectedSteamReference = appState.selectedSteamReference?.game
        let runtimeExecutable = appState.runtimeExecutableURL
        Task {
            defer {
                isCreatingSupportBundle = false
                if let progressNotice {
                    appState.clearNotice(id: progressNotice.id)
                }
            }
            do {
                let url = try await services.supportBundleService.createSupportBundle(
                    diagnostics: decoded.results,
                    checks: systemChecks,
                    selectedSteamReference: selectedSteamReference,
                    runtimeExecutable: runtimeExecutable,
                    launchRecords: supportBundleLaunchRecords,
                    diagnosticRecords: decoded.recordSummaries,
                    steamStoragePaths: steamStoragePaths,
                    synchronizationSelection: synchronizationSelection.rawValue,
                    rendererSelection: rendererSelection.rawValue,
                    videoMemorySelection: videoMemorySelection.rawValue,
                    resolvedVideoMemoryMB: videoMemorySelection.resolvedSizeMB(),
                    incident: incident
                )
                appState.lastSupportBundleURL = url
                appState.presentedSheet = .supportBundle(url)
                if let warning = decoded.warning {
                    appState.setNotice(warning, kind: .warning)
                }
            } catch {
                appState.setError(error)
            }
        }
    }

    private func recentLogEvidence() throws -> (
        text: String,
        context: DiagnosticEvidenceContext,
        readError: Error?
    ) {
        let maxFiles = 8
        let logsRoot = try services.pathManager.url(for: .logs)
        let supportBundlesRoot = try? services.pathManager.url(for: .supportBundles)
        let launchRecord = diagnosticEvidenceLaunchRecord
        let recentFiles: [URL]
        if let launchRecord {
            let directArtifactPaths = [
                launchRecord.stdoutPath,
                launchRecord.stderrPath,
                launchRecord.diagnosticLogPath,
                launchRecord.processObservationPath,
                launchRecord.runEvidencePath
            ].compactMap { $0 }
            let linkedPaths = directArtifactPaths + launchRecord.relatedRunEvidencePaths
            var seen = Set<String>()
            recentFiles = linkedPaths.compactMap { path -> URL? in
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard url.path.hasPrefix(logsRoot.standardizedFileURL.path + "/"),
                      supportBundlesRoot.map({
                        url.path != $0.standardizedFileURL.path &&
                            !url.path.hasPrefix($0.standardizedFileURL.path + "/")
                      }) ?? true,
                      FileSystemItemPolicy.isRegularNonSymlinkFile(url),
                      seen.insert(url.path).inserted else {
                    return nil
                }
                return url
            }.prefix(maxFiles).map { $0 }
            guard !recentFiles.isEmpty else {
                throw DiagnosticEvidenceSelectionError.noLinkedEvidence(launchRecord.id)
            }
        } else {
            recentFiles = try LogTextReader.mostRecentRunLogFiles(
                under: logsRoot,
                maxFiles: maxFiles
            ).filter { url in
                supportBundlesRoot.map {
                    url.standardizedFileURL.path != $0.standardizedFileURL.path &&
                        !url.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/")
                } ?? true
            }
        }
        guard !recentFiles.isEmpty else {
            throw DiagnosticEvidenceSelectionError.noRecentEvidence
        }
        let snapshot = LogTextReader.tolerantDiagnosticSnapshot(from: recentFiles)
        if snapshot.text.isEmpty, let readError = snapshot.readError {
            throw readError
        }

        return (
            snapshot.text,
            DiagnosticEvidenceContext(
                gameID: launchRecord?.gameId ?? appState.selectedSteamReference?.steamAppId,
                launchRecordID: launchRecord?.id
            ),
            snapshot.readError
        )
    }

    @ViewBuilder
    private func diagnosticRecordCard(_ record: DiagnosticRecord) -> some View {
        switch diagnosticDecodeResult(record) {
        case .success(let result):
            DiagnosticResultCard(record: record, result: result)
        case .failure(let error):
            InvalidDiagnosticRecordCard(record: record, error: error)
        }
    }

    private func diagnosticDecodeResult(_ record: DiagnosticRecord) -> Result<DiagnosticResult, Error> {
        Result { try record.requiredDecodedResult() }
    }

    private func decodedDiagnosticsForSupportBundle() -> (
        results: [DiagnosticResult],
        recordSummaries: [SupportBundleDiagnosticRecordSummary],
        warning: String?
    ) {
        var results: [DiagnosticResult] = []
        var recordSummaries: [SupportBundleDiagnosticRecordSummary] = []
        var skippedCount = 0
        for record in records {
            do {
                let result = try record.requiredDecodedResult()
                results.append(result)
                recordSummaries.append(
                    supportBundleDiagnosticRecordSummary(
                        record,
                        decodeStatus: "decoded",
                        resultIdentifier: result.id.uuidString,
                        decodeError: nil
                    )
                )
            } catch {
                skippedCount += 1
                recordSummaries.append(
                    supportBundleDiagnosticRecordSummary(
                        record,
                        decodeStatus: "failed",
                        resultIdentifier: nil,
                        decodeError: supportBundleDiagnosticDecodeError(error)
                    )
                )
            }
        }
        let warning = skippedCount > 0
            ? appState.localizedFormat("%d개 저장된 진단 기록을 읽지 못해 지원 번들에서 제외했습니다.", skippedCount)
            : nil
        return (results, recordSummaries, warning)
    }

    private func supportBundleDiagnosticRecordSummary(
        _ record: DiagnosticRecord,
        decodeStatus: String,
        resultIdentifier: String?,
        decodeError: String?
    ) -> SupportBundleDiagnosticRecordSummary {
        SupportBundleDiagnosticRecordSummary(
            recordIdentifier: record.id,
            gameID: record.gameId,
            launchRecordIdentifier: record.launchRecordId,
            source: record.source,
            createdAt: record.createdAt,
            decodeStatus: decodeStatus,
            resultIdentifier: resultIdentifier,
            decodeError: decodeError
        )
    }

    private func supportBundleDiagnosticDecodeError(_ error: Error) -> String {
        guard let decodeError = error as? DiagnosticRecordDecodeError else {
            return forgePlayTechnicalErrorSummary(error)
        }
        return switch decodeError {
        case .invalidUTF8:
            "The stored diagnostic result is not valid UTF-8."
        case .oversized(_, let byteCount, let limit):
            "The stored diagnostic result is too large to decode: \(byteCount) bytes / limit \(limit) bytes."
        case .decodeFailed:
            "The stored diagnostic result could not be decoded as DiagnosticResult."
        }
    }

    private func aiDiagnosticSensitivePaths() -> [String] {
        DiagnosticPathRedactionPolicy.sensitivePaths(
            rootURL: services.pathManager.rootURL,
            selectedSteamReference: appState.selectedSteamReference?.game,
            runtimeExecutable: appState.runtimeExecutableURL
        )
    }

    private func aiDiagnosticSensitiveTerms() -> [String] {
        DiagnosticPathRedactionPolicy.sensitiveTerms(selectedSteamReference: appState.selectedSteamReference?.game)
    }

    private func save(
        results: [DiagnosticResult],
        source: DiagnosticRecordSource,
        evidenceContext: DiagnosticEvidenceContext
    ) throws {
        try modelContext.insertDiagnosticRecords(
            results,
            gameId: evidenceContext.gameID,
            launchRecordId: evidenceContext.launchRecordID,
            source: source
        )
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

    private func clearTaskLater(_ noticeID: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(2))
            appState.clearNotice(id: noticeID)
        }
    }

    #if DEBUG
    private func applyDebugAIPreviewFixtureIfNeeded() {
        guard appState.debugDiagnosticsPreviewFixture, aiPreview == nil else {
            return
        }
        let rawLog: String
        if appState.debugAppStoreScreenshotFixture {
            rawLog = """
            Authorization: Bearer forgeplay-example-diagnostic-token
            SteamID=76561190000000000
            User path: [REDACTED_PATH]/ForgePlay/Logs/latest.log
            err: msvcp140.dll was not found
            fixme:hid:handle_IRP_MN_QUERY_ID Unhandled type 00000005
            """
        } else {
            rawLog = """
            Authorization: Bearer forgeplay-example-diagnostic-token
            SteamID=76561190000000000
            User path: /Users/\(NSUserName())/Library/Application Support/ForgePlay/Logs/latest.log
            err: msvcp140.dll was not found
            fixme:hid:handle_IRP_MN_QUERY_ID Unhandled type 00000005
            """
        }
        let redactor = services.redactor
        let redacted = redactor.redact(rawLog)
        aiPreview = LLMService.makeRequestSnapshot(
            redactedLog: redacted,
            redactionPreview: redactor.preview(for: rawLog),
            language: appState.effectiveLanguageMode
        )
    }
    #endif
}

private struct SupportIncidentLaunchOption: Identifiable, Hashable {
    var id: String
    var gameName: String?
    var steamAppID: String?
    var occurredAt: Date
    var status: String
    var commandKind: String

    init(_ record: LaunchRecord) {
        id = record.id
        gameName = record.gameName
        steamAppID = record.gameId
        occurredAt = record.startedAt
        status = record.status
        commandKind = record.commandKind
    }

    var displayTitle: String {
        let target = gameName ?? steamAppID ?? commandKind
        return "\(target) · \(status) · \(occurredAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct SupportIncidentDraft: Identifiable, Hashable {
    var id: String
    var launchRecordIdentifier: String?
    var steamAppID: String
    var gameName: String
    var occurredAt: Date
    var expectedResult: String
    var actualSymptoms: String
    var reproductionSteps: String
    var userNotes: String

    init(record: LaunchRecord?) {
        id = UUID().uuidString.lowercased()
        launchRecordIdentifier = record?.id
        steamAppID = record?.gameId ?? ""
        gameName = record?.gameName ?? ""
        occurredAt = record?.startedAt ?? Date()
        expectedResult = ""
        actualSymptoms = record?.failureSummary ?? record?.steamUIVerificationDetail ?? ""
        reproductionSteps = ""
        userNotes = ""
    }

    var context: SupportIncidentContext {
        SupportIncidentContext(
            incidentIdentifier: id,
            launchRecordIdentifier: launchRecordIdentifier,
            steamAppID: steamAppID,
            gameName: gameName,
            occurredAt: occurredAt,
            expectedResult: expectedResult,
            actualSymptoms: actualSymptoms,
            reproductionSteps: reproductionSteps,
            userNotes: userNotes
        )
    }

    mutating func apply(_ option: SupportIncidentLaunchOption) {
        launchRecordIdentifier = option.id
        steamAppID = option.steamAppID ?? ""
        gameName = option.gameName ?? ""
        occurredAt = option.occurredAt
    }
}

private struct SupportBundlePreparationView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: SupportIncidentDraft

    let launchOptions: [SupportIncidentLaunchOption]
    let onCancel: () -> Void
    let onCreate: (SupportIncidentDraft) -> Void

    init(
        initialDraft: SupportIncidentDraft,
        launchOptions: [SupportIncidentLaunchOption],
        onCancel: @escaping () -> Void,
        onCreate: @escaping (SupportIncidentDraft) -> Void
    ) {
        _draft = State(initialValue: initialDraft)
        self.launchOptions = launchOptions
        self.onCancel = onCancel
        self.onCreate = onCreate
    }

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.localized("지원 번들 준비"))
                            .font(.title2.weight(.bold))
                        Text(appState.localized("문제 발생 정보를 확인하고 전송 전 포함 범위와 개인정보 안내를 검토하세요."))
                            .font(.callout)
                            .foregroundStyle(palette.secondaryText)
                    }
                } icon: {
                    Image(systemName: "doc.zipper")
                        .font(.title2)
                        .foregroundStyle(palette.primary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(appState.localized("문제 발생 정보"))
                        .font(.headline)

                    Picker(appState.localized("대상 실행"), selection: $draft.launchRecordIdentifier) {
                        Text(appState.localized("연결하지 않음")).tag(String?.none)
                        ForEach(launchOptions) { option in
                            Text(option.displayTitle).tag(Optional(option.id))
                        }
                    }
                    .onChange(of: draft.launchRecordIdentifier) { _, identifier in
                        guard let identifier,
                              let option = launchOptions.first(where: { $0.id == identifier }) else {
                            return
                        }
                        draft.apply(option)
                    }

                    LabeledContent(appState.localized("게임 이름")) {
                        TextField("", text: $draft.gameName)
                            .frame(minWidth: 280)
                    }
                    LabeledContent(appState.localized("Steam App ID")) {
                        TextField("", text: $draft.steamAppID)
                            .frame(minWidth: 280)
                    }
                    DatePicker(
                        appState.localized("발생 시각"),
                        selection: $draft.occurredAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )

                    incidentEditor("기대 결과", text: $draft.expectedResult, height: 64)
                    incidentEditor("실제 증상", text: $draft.actualSymptoms, height: 76)
                    if !hasActualSymptoms {
                        Label(
                            appState.localized("실제 증상을 입력해야 지원 번들을 만들 수 있습니다."),
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(CheckStatus.warning.color(in: palette))
                    }
                    incidentEditor("재현 절차", text: $draft.reproductionSteps, height: 92)
                    incidentEditor("추가 메모", text: $draft.userNotes, height: 76)
                }
                .padding(14)
                .background(palette.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(palette.border, lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 8) {
                    Label(appState.localized("포함 범위와 개인정보"), systemImage: "hand.raised")
                        .font(.headline)
                    Text(appState.localized("로컬 ZIP에 가림 처리한 로그와 진단, 실행 기록과 프리픽스 메타데이터, 앱·Mac·Runtime·그래픽·디스플레이·저장공간 상태를 포함합니다."))
                    Text(appState.localized("스크린샷과 바이너리 크래시 덤프는 포함하지 않습니다."))
                    Text(appState.localized("가림 처리는 완전한 보장이 아닙니다. 비밀번호, Steam Guard 코드, 토큰을 입력하지 말고 공유 전에 README와 파일 내용을 확인하세요."))
                        .fontWeight(.semibold)
                }
                .font(.callout)
                .foregroundStyle(palette.secondaryText)
                .padding(14)
                .background(CheckStatus.warning.color(in: palette).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                ResponsiveActionRow(alignment: .trailing) {
                    ThemedActionButton(
                        title: "취소",
                        systemImage: "xmark",
                        prominence: .secondary,
                        action: onCancel
                    )
                    .frame(width: 130)
                    ThemedActionButton(
                        title: "이 정보로 지원 번들 생성",
                        systemImage: "doc.zipper",
                        prominence: .primary,
                        isDisabled: !hasActualSymptoms
                    ) {
                        onCreate(draft)
                    }
                    .frame(minWidth: 220)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(24)
        }
        .frame(minWidth: 640, minHeight: 680)
    }

    private var hasActualSymptoms: Bool {
        !draft.actualSymptoms.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func incidentEditor(
        _ title: String,
        text: Binding<String>,
        height: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(appState.localized(title))
                .font(.subheadline.weight(.semibold))
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: height)
                .padding(6)
                .background(.background.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

private struct DiagnosticResultCard: View {
    var record: DiagnosticRecord
    var result: DiagnosticResult
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \PrefixRecord.displayName) private var prefixes: [PrefixRecord]
    @Query(sort: \SteamGameRecord.name) private var games: [SteamGameRecord]
    @Query(sort: \RuntimeRecord.runtime) private var runtimes: [RuntimeRecord]
    @State private var pendingAction: RecommendedAction?
    @State private var isApplying = false
    @State private var isShowingDeleteConfirmation = false

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    var body: some View {
        ForgeCard(result.category.beginnerTitle, systemImage: "stethoscope") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RiskBadge(risk: result.riskLevel)
                    Text(appState.localizedFormat("%d%% 신뢰도 · %@", Int(result.confidence * 100), diagnosticSourceText(record.source)))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                    Text(record.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                    deleteRecordButton
                }
                Text(result.localizedUserMessage(appState: appState))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(appState.localized("기술 요약 보기")) {
                    Text(result.localizedTechnicalSummary(appState: appState))
                        .font(.system(.caption, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !result.recommendedActions.isEmpty {
                    Divider()
                    Text(appState.localized("권장 조치"))
                        .font(.headline)
                    ForEach(result.recommendedActions) { action in
                        actionRow(action)
                    }
                }
            }
        }
        .confirmationDialog(
            appState.localized("자동 수정을 적용할까요?"),
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingAction {
                Button(appState.localized(
                    pendingAction.mutatesPrefixMetadata ? "스냅샷을 만들고 적용" : "적용"
                )) {
                    apply(pendingAction)
                }
            }
            Button(appState.localized("취소"), role: .cancel) {}
        } message: {
            if let pendingAction {
                Text(pendingAction.localizedReason(appState: appState))
            }
        }
        .confirmationDialog(
            appState.localized("진단 기록을 삭제할까요?"),
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(appState.localized("진단 기록 삭제"), role: .destructive) {
                deleteRecord()
            }
            Button(appState.localized("취소"), role: .cancel) {}
        } message: {
            Text(appState.localized("이 진단 기록만 삭제합니다. 로그 파일, 실행 기록, 게임 기록은 삭제하지 않습니다."))
        }
    }

    private var deleteRecordButton: some View {
        Button {
            isShowingDeleteConfirmation = true
        } label: {
            Image(systemName: "trash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.secondaryText)
                .frame(width: 36, height: 36)
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
        .accessibilityLabel(appState.localized("진단 기록 삭제"))
    }

    private func diagnosticSourceText(_ source: String) -> String {
        if let recordSource = DiagnosticRecordSource(storageValue: source) {
            return appState.localized(recordSource.label)
        }
        return appState.localizedFormat("알 수 없는 진단 출처: %@", source)
    }

    private func actionRow(_ action: RecommendedAction) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                actionIcon(action)
                actionText(action)
                Spacer(minLength: 12)
                actionControlColumn(action, trailing: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    actionIcon(action)
                    actionText(action)
                }
                actionControlColumn(action, trailing: false)
                    .padding(.leading, 32)
            }
        }
        .padding(10)
        .background(palette.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func actionIcon(_ action: RecommendedAction) -> some View {
        Image(systemName: "wrench.adjustable")
            .foregroundStyle(action.riskLevel.color(in: palette))
            .frame(width: 22)
            .padding(.top, 2)
    }

    private func actionText(_ action: RecommendedAction) -> some View {
        let steps = action.localizedRemediationSteps(
            appState: appState,
            runtimeDefinition: runtimeDefinition(for: action)
        )

        return VStack(alignment: .leading, spacing: 6) {
            Text(appState.localized(action.type.beginnerLabel))
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(action.localizedReason(appState: appState))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            RemediationStepsView(steps: steps)
                .padding(.top, 2)
        }
    }

    private func actionControlColumn(_ action: RecommendedAction, trailing: Bool) -> some View {
        let alignment: HorizontalAlignment = trailing ? .trailing : .leading

        return VStack(alignment: alignment, spacing: 8) {
            RiskBadge(risk: action.riskLevel)
            actionControls(for: action)
        }
    }

    private func runtimeDefinition(for action: RecommendedAction) -> RuntimeDefinition? {
        guard action.type == .installRuntime, let runtime = action.runtime else { return nil }
        return services.runtimeManager.definition(for: runtime)
    }

    @ViewBuilder
    private func actionControls(for action: RecommendedAction) -> some View {
        switch action.type {
        case .installRuntime:
            if let runtime = action.runtime {
                diagnosticActionButton(
                    title: "공식 페이지",
                    systemImage: "safari",
                    prominence: .secondary
                ) {
                    if let url = services.runtimeManager.definition(for: runtime).officialURL {
                        appState.openExternalURL(url)
                    }
                }
            }
            diagnosticActionButton(
                title: "설치 안내",
                systemImage: "square.and.arrow.down",
                prominence: .primary,
                isDisabled: isApplying || appState.runtimeExecutableURL == nil || !canRunBundledWindowsRuntime
            ) {
                if let runtime = action.runtime {
                    appState.presentedSheet = .chooseRuntimeInstaller(runtime)
                }
            }
        case .setWindowsVersion, .setDLLOverride:
            diagnosticActionButton(
                title: "적용",
                systemImage: "checkmark.circle",
                prominence: .primary,
                isDisabled: isApplying || appState.runtimeExecutableURL == nil || !canRunBundledWindowsRuntime
            ) {
                pendingAction = action
            }
        case .askUserToUpdateRuntime:
            diagnosticActionButton(
                title: "ForgePlay Runtime 업데이트 안내",
                systemImage: "arrow.down.app",
                prominence: .primary,
                isDisabled: isApplying
            ) {
                pendingAction = action
            }
        case .addLaunchOption, .markUnsupported:
            EmptyView()
        case .importAppleSupplementalRenderer:
            diagnosticActionButton(
                title: "Apple D3DMetal 보조 렌더러 가져오기",
                systemImage: "shippingbox",
                prominence: .secondary,
                isDisabled: !canRunBundledWindowsRuntime
            ) {
                appState.presentedSheet = .importAppleSupplementalRenderer
            }
        case .askUserToUpdateMacOS:
            diagnosticActionButton(
                title: "macOS 업데이트",
                systemImage: "gearshape.arrow.triangle.2.circlepath",
                prominence: .secondary
            ) {
                appState.openExternalURL(ExternalLinkPolicy.macOSSoftwareUpdateSettingsURL)
            }
        case .noAction:
            EmptyView()
        }
    }

    private func diagnosticActionButton(
        title: String,
        systemImage: String,
        prominence: ThemedActionButton.Prominence,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        ThemedActionButton(
            title: title,
            systemImage: systemImage,
            prominence: prominence,
            isDisabled: isDisabled,
            controlSize: .small,
            action: action
        )
        .frame(minWidth: 132, idealWidth: 152, maxWidth: 188)
    }

    private var canRunBundledWindowsRuntime: Bool {
        ForgePlayRuntimeCapabilityPolicy.canRunBundledWindowsRuntime
    }

    private var bundledRuntimeUnavailableReason: String {
        appState.localized(ForgePlayRuntimeCapabilityPolicy.unavailableReasonKey)
    }

    private func apply(_ action: RecommendedAction) {
        if action.requiresWindowsRuntime && !canRunBundledWindowsRuntime {
            appState.setNotice(bundledRuntimeUnavailableReason, kind: .warning)
            pendingAction = nil
            return
        }
        if action.type == .installRuntime {
            if let runtime = action.runtime {
                appState.presentedSheet = .chooseRuntimeInstaller(runtime)
            }
            pendingAction = nil
            return
        }

        let installerURL: URL? = nil

        isApplying = true
        appState.setTask(appState.localized("자동 수정을 적용하는 중입니다."))
        Task {
            defer { isApplying = false }
            do {
                let preparedPrefix = try await preparedPrefix(for: action)
                let result = try await services.autoFixService.apply(
                    action: action,
                    prefixURL: preparedPrefix.url,
                    runtimeExecutable: appState.runtimeExecutableURL,
                    installerURL: installerURL
                )
                let isFailed = result.processResult.map { !$0.succeeded } ?? false
                do {
                    try persist(
                        result: result,
                        prefixURL: preparedPrefix.url,
                        prefixRecord: preparedPrefix.record
                    )
                    try modelContext.saveOrRollback()
                } catch let persistenceError {
                    modelContext.rollback()
                    let didApplyOutsideModelContext = result.processResult.map { $0.succeeded } ??
                        result.action.changesOutsideModelContext
                    guard didApplyOutsideModelContext else {
                        throw persistenceError
                    }
                    let persistenceMessage = appState.localizedFormat(
                        "자동 수정은 적용됐지만 기록을 저장하지 못했습니다: %@",
                        forgePlayTechnicalErrorSummary(persistenceError)
                    )
                    appState.setNotice(
                        DiagnosticWarningText.combined(
                            persistenceMessage,
                            preparedPrefix.persistenceWarning
                        ) ?? persistenceMessage,
                        kind: .warning,
                        logURL: result.processResult?.stderrLog
                    )
                    return
                }
                let message = DiagnosticWarningText.combined(
                    result.localizedMessage(appState: appState),
                    preparedPrefix.persistenceWarning
                ) ?? result.localizedMessage(appState: appState)
                let notice = appState.setNotice(
                    message,
                    kind: isFailed ? .failure : (preparedPrefix.persistenceWarning == nil ? .success : .warning),
                    logURL: result.processResult?.stderrLog
                )
                if !isFailed && preparedPrefix.persistenceWarning == nil {
                    clearNoticeLater(notice.id)
                }
            } catch {
                appState.setError(error)
            }
        }
    }

    private func preparedPrefix(for action: RecommendedAction) async throws -> (url: URL, record: PrefixRecord?, persistenceWarning: String?) {
        guard action.requiresWineExecution else {
            let prefixURL = try preferredPrefixURL()
            return (prefixURL, preferredPrefixRecord(prefixURL: prefixURL), nil)
        }

        guard let runtimeExecutable = appState.runtimeExecutableURL else {
            throw AutoFixServiceError.missingBundledRuntime
        }

        let preparation = try await services.prepareSteamPrefix(
            runtimeExecutable: runtimeExecutable,
            synchronizationSelection: appState.wineSynchronizationSelection
        )
        let cleanupWarning = preparation.localizedPreviousEnvironmentCleanupWarning(appState: appState)
        do {
            let prefixRecord = try PrefixRecord.upsert(metadata: preparation.metadata, in: modelContext)
            try modelContext.saveOrRollback()
            return (URL(fileURLWithPath: preparation.metadata.path), prefixRecord, cleanupWarning)
        } catch {
            modelContext.rollback()
            return (
                URL(fileURLWithPath: preparation.metadata.path),
                nil,
                DiagnosticWarningText.combined(
                    appState.localizedFormat(
                        "Steam 프리픽스는 준비됐지만 기록을 저장하지 못했습니다: %@",
                        forgePlayTechnicalErrorSummary(error)
                    ),
                    cleanupWarning
                )
            )
        }
    }

    private func preferredPrefixURL() throws -> URL {
        if let steamPrefix = prefixes.first(where: { $0.id == PrefixIdentifier.steamShared }) {
            return URL(fileURLWithPath: steamPrefix.path)
        }
        return try services.pathManager.url(for: .steamSharedPrefix)
    }

    private func preferredPrefixRecord(prefixURL: URL) -> PrefixRecord? {
        prefixes.first { $0.id == PrefixIdentifier.steamShared && $0.path == prefixURL.path } ??
            prefixes.first { $0.id == PrefixIdentifier.steamShared }
    }

    private func persist(
        result: AutoFixExecutionResult,
        prefixURL: URL,
        prefixRecord: PrefixRecord?
    ) throws {
        modelContext.insert(AutoFixRecord(
            diagnosticId: record.id,
            actionType: result.action.type,
            status: result.processResult.map { $0.succeeded ? "applied" : "failed" } ?? "applied",
            snapshotPath: result.snapshotURL?.path,
            logPath: result.processResult?.stderrLog.path
        ))

        let synchronizedPrefixRecord = result.action.mutatesPrefixMetadata
            ? try syncPrefixRecord(at: prefixURL)
            : prefixRecord

        if result.action.type == .markUnsupported,
           let gameId = record.gameId,
           let game = games.first(where: { $0.steamAppId == gameId }) {
            game.lastLaunchStatus = "unsupported"
        }

        if result.processResult?.succeeded == true,
           result.action.type == .installRuntime,
           let runtime = result.action.runtime,
           let prefixRecord = synchronizedPrefixRecord {
            let id = "\(prefixRecord.id)-\(runtime.rawValue)"
            let record = runtimes.first { $0.id == id } ?? RuntimeRecord(id: id, prefixId: prefixRecord.id, runtime: runtime)
            record.status = "installed"
            record.installedAt = Date()
            record.installerSource = "user-selected-autofix"
            record.installLogPath = result.processResult?.stdoutLog.path
            if !runtimes.contains(where: { $0.id == id }) {
                modelContext.insert(record)
            }
        }
    }

    @discardableResult
    private func syncPrefixRecord(at prefixURL: URL) throws -> PrefixRecord {
        let metadata = try services.prefixManager.loadMetadata(at: prefixURL)
        return try PrefixRecord.upsert(metadata: metadata, in: modelContext)
    }

    private func deleteRecord() {
        modelContext.delete(record)
        do {
            try modelContext.saveOrRollback()
            let notice = appState.setNotice(appState.localized("진단 기록을 삭제했습니다."), kind: .success)
            clearNoticeLater(notice.id)
        } catch {
            appState.setError(error)
        }
    }

    private func clearNoticeLater(_ noticeID: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(3))
            appState.clearNotice(id: noticeID)
        }
    }
}

private struct InvalidDiagnosticRecordCard: View {
    var record: DiagnosticRecord
    var error: Error
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingDeleteConfirmation = false

    private var palette: ForgePlayPalette {
        ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)
    }

    var body: some View {
        ForgeCard("저장된 진단 기록 오류", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text(appState.localizedError(error))
                        .font(.callout)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Button {
                        isShowingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.secondaryText)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ForgeActionButtonStyle(liftsOnHover: false))
                    .accessibilityLabel(appState.localized("진단 기록 삭제"))
                }
                Text(record.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .confirmationDialog(
            appState.localized("진단 기록을 삭제할까요?"),
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(appState.localized("진단 기록 삭제"), role: .destructive) {
                deleteRecord()
            }
            Button(appState.localized("취소"), role: .cancel) {}
        } message: {
            Text(appState.localized("이 진단 기록만 삭제합니다. 로그 파일, 실행 기록, 게임 기록은 삭제하지 않습니다."))
        }
    }

    private func deleteRecord() {
        modelContext.delete(record)
        do {
            try modelContext.saveOrRollback()
            let notice = appState.setNotice(appState.localized("진단 기록을 삭제했습니다."), kind: .success)
            clearNoticeLater(notice.id)
        } catch {
            appState.setError(error)
        }
    }

    private func clearNoticeLater(_ noticeID: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(3))
            appState.clearNotice(id: noticeID)
        }
    }
}

private extension RecommendedAction {
    var requiresWindowsRuntime: Bool {
        switch type {
        case .installRuntime, .setWindowsVersion, .setDLLOverride:
            true
        case .addLaunchOption, .importAppleSupplementalRenderer, .markUnsupported, .askUserToUpdateRuntime, .askUserToUpdateMacOS, .noAction:
            false
        }
    }

    var requiresWineExecution: Bool {
        switch type {
        case .installRuntime, .setWindowsVersion, .setDLLOverride:
            true
        case .addLaunchOption, .importAppleSupplementalRenderer, .markUnsupported, .askUserToUpdateRuntime, .askUserToUpdateMacOS, .noAction:
            false
        }
    }

    var mutatesPrefixMetadata: Bool {
        switch type {
        case .installRuntime, .setWindowsVersion, .setDLLOverride:
            true
        case .addLaunchOption, .importAppleSupplementalRenderer, .markUnsupported, .askUserToUpdateRuntime, .askUserToUpdateMacOS, .noAction:
            false
        }
    }

    var changesOutsideModelContext: Bool {
        switch type {
        case .installRuntime, .setWindowsVersion, .setDLLOverride:
            true
        case .addLaunchOption, .importAppleSupplementalRenderer, .markUnsupported, .askUserToUpdateRuntime, .askUserToUpdateMacOS, .noAction:
            false
        }
    }
}
