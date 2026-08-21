import SwiftUI

private enum CompatibilityCatalogFilter: String, CaseIterable, Identifiable {
    case all
    case playable
    case testing
    case blocked
    case unknown

    var id: String { rawValue }

    var status: CompatibilityCatalogStatus? {
        self == .all ? nil : CompatibilityCatalogStatus(rawValue: rawValue)
    }

    var labelKey: String {
        switch self {
        case .all: "전체"
        case .playable: "실행 가능"
        case .testing: "확인 중"
        case .blocked: "실행 차단"
        case .unknown: "정보 부족"
        }
    }
}

struct CompatibilityCatalogView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.colorScheme) private var colorScheme
    @State private var snapshot: CompatibilityCatalogSnapshot?
    @State private var snapshotOrigin: CompatibilityCatalogOrigin = .bundled
    @State private var loadError: String?
    @State private var refreshStatusMessage: String?
    @State private var refreshStatusIsFailure = false
    @State private var isRefreshing = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var catalogLoadGeneration = 0
    @State private var searchText = ""
    @State private var selectedFilter: CompatibilityCatalogFilter = .all

    private let catalogService = CompatibilityCatalogService()

    var body: some View {
        let palette = ForgePlayTheme.palette(mode: appState.themeMode, colorScheme: colorScheme)

        ForgePageScaffold(
            "호환성 목록",
            subtitle: "릴리스 전에 확인된 게임별 실행 증거와 알려진 제한을 확인합니다.",
            systemImage: "list.bullet.rectangle"
        ) {
            catalogLinks
        } content: {
            ForgeSection(
                "공개 호환성 목록",
                subtitle: "이 목록은 실행 증거를 보여주며 Steam 실행 설정을 자동으로 바꾸지 않습니다.",
                systemImage: "testtube.2"
            ) {
                Text(appState.localized(
                    "현재 목록은 릴리스 전에 확인한 내용입니다. 이후 릴리스 업데이트에서 항목과 상태가 추가되거나 변경될 수 있으며, 최신 회신 상태는 홈페이지에서 확인할 수 있습니다."
                ))
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let snapshot {
                    Text(appState.localizedFormat(
                        "데이터 출처 %@ · 목록 기준일 %@ · 제보 %d건",
                        originLabel,
                        snapshot.updatedAt,
                        snapshot.reports.count
                    ))
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.secondaryText)
                }

                if let refreshStatusMessage {
                    Text(refreshStatusMessage)
                        .font(.caption)
                        .foregroundStyle(refreshStatusIsFailure ? palette.warning : palette.success)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(appState.localized(
                    "GitHub 이슈에 사용 중인 Mac 기기, macOS 릴리스 버전, ForgePlay 릴리스 버전과 특이사항을 적어주면 향후 호환성 개선에 도움이 됩니다. 비밀번호나 Steam Guard 코드는 첨부하지 마세요."
                ))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForgeSection(
                "게임별 확인 결과",
                subtitle: "게임 이름과 상태로 목록을 좁힐 수 있습니다.",
                systemImage: "magnifyingglass"
            ) {
                TextField(appState.localized("게임 검색"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 520)

                Picker(appState.localized("호환성 상태"), selection: $selectedFilter) {
                    ForEach(CompatibilityCatalogFilter.allCases) { filter in
                        Text(appState.localized(filter.labelKey)).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 640)

                catalogContent(palette: palette)
            }
        }
        .task(id: catalogLoadGeneration) {
            await loadCatalogIfNeeded()
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    private var catalogLinks: some View {
        ResponsiveActionRow(alignment: .trailing, spacing: 8) {
            SectionHelpButton(section: .compatibilityCatalog)
            SecondaryActionButton(
                title: isRefreshing ? "갱신 중" : "공개 호환성 목록 갱신",
                systemImage: "arrow.clockwise",
                isDisabled: isRefreshing || snapshot == nil
            ) {
                refreshCatalog()
            }
            SecondaryActionButton(title: "홈페이지 최신 목록", systemImage: "safari") {
                appState.openExternalURL(ExternalLinkPolicy.compatibilityWebsiteURL)
            }
            SecondaryActionButton(title: "호환성 제보", systemImage: "bubble.left.and.exclamationmark.bubble.right") {
                appState.openExternalURL(ExternalLinkPolicy.compatibilityReportURL)
            }
        }
    }

    @ViewBuilder
    private func catalogContent(palette: ForgePlayPalette) -> some View {
        if let loadError {
            VStack(spacing: 12) {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "호환성 목록을 읽지 못했습니다",
                    message: loadError,
                    fillsAvailableHeight: false
                )
                ThemedActionButton(
                    title: "다시 시도",
                    systemImage: "arrow.clockwise",
                    prominence: .secondary
                ) {
                    retryCatalogLoad()
                }
                .frame(maxWidth: 240)
                .accessibilityHint(appState.localized("앱 포함 공개 호환성 목록 다시 읽기"))
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if snapshot == nil {
            ProgressView(appState.localized("호환성 목록을 읽는 중입니다."))
                .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
        } else {
            let entries = filteredEntries
            if entries.isEmpty {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "조건에 맞는 호환성 제보 없음",
                    message: "검색어나 상태 필터를 바꿔보세요.",
                    fillsAvailableHeight: false
                )
                .frame(minHeight: 180)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(entries) { entry in
                        catalogCard(entry, palette: palette)
                    }
                }
            }
        }
    }

    private var filteredEntries: [CompatibilityCatalogEntry] {
        guard let snapshot else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: appState.locale)
        return catalogService.entries(in: snapshot)
            .filter { entry in
                guard selectedFilter.status.map({ entry.report.status == $0 }) ?? true else {
                    return false
                }
                guard !query.isEmpty else { return true }
                let searchable = [
                    entry.game.localizedTitle(for: appState.languageMode),
                    entry.game.titles["en"],
                    entry.game.titles["ko"],
                    entry.report.reporter,
                    entry.report.localizedNote(for: appState.languageMode)
                ]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: appState.locale)
                return searchable.contains(query)
            }
            .sorted {
                $0.game.localizedTitle(for: appState.languageMode)
                    .localizedStandardCompare($1.game.localizedTitle(for: appState.languageMode)) == .orderedAscending
            }
    }

    private func catalogCard(
        _ entry: CompatibilityCatalogEntry,
        palette: ForgePlayPalette
    ) -> some View {
        ForgeCard(entry.game.localizedTitle(for: appState.languageMode), systemImage: "gamecontroller") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    StatusBadge(
                        label: statusLabel(for: entry.report.status),
                        status: checkStatus(for: entry.report.status)
                    )
                    if let blocker = entry.report.blocker {
                        StatusBadge(label: blockerLabel(for: blocker), status: .warning)
                    }
                    Spacer(minLength: 0)
                }

                Text(evidenceSummary(for: entry))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let note = entry.report.localizedNote(for: appState.languageMode) {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(appState.localized(
                        entry.report.status == .playable
                            ? "실행 가능 제보가 있으며 세부 특이사항은 기록되지 않았습니다."
                            : "세부 특이사항이 아직 충분히 기록되지 않았습니다."
                    ))
                        .font(.callout)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func evidenceSummary(for entry: CompatibilityCatalogEntry) -> String {
        var fields = [sourceLabel(for: entry.report.source)]
        if let reporter = entry.report.reporter {
            fields.append("@\(reporter)")
        }
        if let testedAt = entry.report.testedAt {
            fields.append(testedAt)
        } else {
            fields.append(appState.localized("확인 날짜 미제공"))
        }
        if let profile = entry.testProfile {
            var profileFields = [profile.platform, profile.chip]
            if let memory = profile.unifiedMemoryGB {
                profileFields.append("\(memory) GB")
            }
            if let macOSVersion = profile.macOSVersion {
                profileFields.append("macOS \(macOSVersion)")
            }
            fields.append(profileFields.joined(separator: " · "))
        } else {
            fields.append(appState.localized("Mac·OS 세부 정보 미제공"))
        }
        if let forgePlayVersion = entry.report.forgePlayVersion {
            fields.append(appState.localizedFormat("ForgePlay %@", forgePlayVersion))
        }
        if let gameVersion = entry.report.gameVersion {
            fields.append(appState.localizedFormat("게임 버전 %@", gameVersion))
        }
        return fields.joined(separator: " · ")
    }

    private func statusLabel(for status: CompatibilityCatalogStatus) -> String {
        let localizationKey = switch status {
        case .playable: "실행 가능"
        case .testing: "확인 중"
        case .blocked: "실행 차단"
        case .unknown: "정보 부족"
        }
        return appState.localized(localizationKey)
    }

    private func checkStatus(for status: CompatibilityCatalogStatus) -> CheckStatus {
        switch status {
        case .playable: .ok
        case .testing: .warning
        case .blocked: .error
        case .unknown: .unknown
        }
    }

    private func sourceLabel(for source: CompatibilityCatalogSource) -> String {
        switch source {
        case .projectTest: appState.localized("프로젝트 확인")
        case .githubIssue: appState.localized("GitHub 이슈")
        case .communityReport: appState.localized("커뮤니티 제보")
        }
    }

    private func blockerLabel(for blocker: CompatibilityCatalogBlocker) -> String {
        let localizationKey = switch blocker {
        case .antiCheat: "안티치트 제한"
        case .launcher: "런처 제한"
        case .graphics: "그래픽 제한"
        case .runtime: "런타임 제한"
        case .securityModule: "보안 모듈 제한"
        case .unknown: "원인 확인 중"
        }
        return appState.localized(localizationKey)
    }

    private var originLabel: String {
        switch snapshotOrigin {
        case .bundled:
            appState.localized("앱 포함 데이터")
        case .cached, .refreshed:
            appState.localized("홈페이지에서 갱신한 데이터")
        }
    }

    private func loadCatalogIfNeeded() async {
        guard snapshot == nil, loadError == nil else { return }
        do {
            let loaded = try await services.compatibilityCatalogRepository.loadCurrent()
            guard !Task.isCancelled else { return }
            snapshot = loaded.snapshot
            snapshotOrigin = loaded.origin
            if let cacheWarningKey = loaded.cacheWarningKey {
                refreshStatusMessage = appState.localized(cacheWarningKey)
                refreshStatusIsFailure = true
            }
        } catch {
            guard !Task.isCancelled else { return }
            loadError = localizedCatalogError(error)
        }
    }

    private func retryCatalogLoad() {
        guard snapshot == nil, !isRefreshing else { return }
        loadError = nil
        refreshStatusMessage = nil
        refreshStatusIsFailure = false
        catalogLoadGeneration += 1
    }

    private func refreshCatalog() {
        guard let current = snapshot, !isRefreshing else { return }
        isRefreshing = true
        refreshStatusMessage = nil
        refreshStatusIsFailure = false
        refreshTask = Task { @MainActor in
            defer {
                isRefreshing = false
                refreshTask = nil
            }
            do {
                let loaded = try await services.compatibilityCatalogRepository.refresh(current: current)
                guard !Task.isCancelled else { return }
                snapshot = loaded.snapshot
                snapshotOrigin = loaded.origin
                refreshStatusMessage = appState.localized(
                    loaded.snapshot.updatedAt == current.updatedAt
                        ? "공식 홈페이지의 공개 호환성 목록이 현재 목록과 동일함을 확인했습니다."
                        : "공식 홈페이지의 공개 호환성 목록을 확인하고 안전하게 저장했습니다."
                )
            } catch {
                guard !Task.isCancelled else { return }
                refreshStatusMessage = appState.localizedFormat(
                    "현재 호환성 목록은 그대로 유지됩니다. %@",
                    localizedCatalogError(error)
                )
                refreshStatusIsFailure = true
            }
        }
    }

    private func localizedCatalogError(_ error: Error) -> String {
        if let repositoryError = error as? CompatibilityCatalogRepositoryError {
            switch repositoryError {
            case .officialEndpointUnavailable:
                return appState.localized("공식 공개 호환성 목록 주소를 확인할 수 없습니다.")
            case .invalidResolvedURL:
                return appState.localized("공개 호환성 목록이 허용되지 않은 주소로 이동하여 갱신을 중단했습니다.")
            case .invalidHTTPStatus(let statusCode):
                return appState.localizedFormat(
                    "공개 호환성 목록 서버 응답이 올바르지 않습니다: HTTP %d",
                    statusCode
                )
            case .responseTooLarge(let byteCount, let limit):
                return appState.localizedFormat(
                    "공개 호환성 목록 응답이 너무 큽니다: %d bytes / limit %d bytes",
                    byteCount,
                    limit
                )
            case .rollback(let current, let received):
                return appState.localizedFormat(
                    "현재 목록보다 오래된 공개 호환성 목록은 적용하지 않습니다: current %@, received %@",
                    current,
                    received
                )
            case .revisionConflict(let updatedAt):
                return appState.localizedFormat(
                    "같은 기준일의 공개 호환성 목록 내용이 달라 갱신을 적용하지 않았습니다: %@",
                    updatedAt
                )
            case .cacheUnavailable:
                return appState.localized("공개 호환성 목록 캐시 위치를 안전하게 준비할 수 없습니다.")
            case .cacheCommitFailed:
                return appState.localized("공개 호환성 목록 캐시를 안전하게 저장하지 못했습니다.")
            case .refreshInProgress:
                return appState.localized("공개 호환성 목록 갱신이 이미 진행 중입니다.")
            }
        }
        if let serviceError = error as? CompatibilityCatalogServiceError {
            switch serviceError {
            case .bundledSnapshotMissing:
                return appState.localized("앱에 포함된 호환성 목록을 찾을 수 없습니다.")
            case .unsafeSnapshot(let url):
                return appState.localizedFormat(
                    "호환성 목록이 안전한 일반 파일이 아닙니다: %@",
                    url.lastPathComponent
                )
            case .snapshotTooLarge(let size, let limit):
                return appState.localizedFormat(
                    "호환성 목록이 너무 큽니다: %d bytes / limit %d bytes",
                    size,
                    limit
                )
            case .snapshotDecodeFailed:
                return appState.localized("앱에 포함된 호환성 목록을 읽을 수 없습니다.")
            case .unsupportedSchemaVersion(let version):
                return appState.localizedFormat("지원하지 않는 호환성 목록 형식입니다: %d", version)
            case .invalidUpdatedAt(let value):
                return appState.localizedFormat("호환성 목록 갱신 날짜가 올바르지 않습니다: %@", value)
            case .invalidIdentifier(let value):
                return appState.localizedFormat("호환성 목록 식별자가 올바르지 않습니다: %@", value)
            case .duplicateIdentifier(let value):
                return appState.localizedFormat("호환성 목록 식별자가 중복되었습니다: %@", value)
            case .invalidLocalizedText(let value):
                return appState.localizedFormat("호환성 목록의 다국어 텍스트가 올바르지 않습니다: %@", value)
            case .invalidTestProfile(let value):
                return appState.localizedFormat("호환성 목록의 테스트 환경이 올바르지 않습니다: %@", value)
            case .danglingGameReference(let value):
                return appState.localizedFormat("호환성 제보가 존재하지 않는 게임을 가리킵니다: %@", value)
            case .danglingTestProfileReference(let value):
                return appState.localizedFormat("호환성 제보가 존재하지 않는 테스트 환경을 가리킵니다: %@", value)
            case .countLimitExceeded(let collection, let count, let limit):
                return appState.localizedFormat(
                    "호환성 목록 항목이 제한을 넘었습니다: %@ %d / %d",
                    collection,
                    count,
                    limit
                )
            }
        }
        return appState.localized("공개 호환성 목록을 갱신하지 못했습니다. 네트워크 연결을 확인하고 다시 시도하세요.")
    }
}
