import SwiftData
import SwiftUI

struct ManagedStorageLocationView: View {
    private enum ReconnectKind: Equatable {
        case legacy
        case current
    }

    private struct ReconnectRequest {
        var kind: ReconnectKind
        var path: String
        var requiresAuthorization: Bool
        var requiresMigrationDecision: Bool
    }

    private struct RelocationRequest {
        var source: URL
        var destination: URL
        var bookmark: Data?
    }

    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var settingsRecords: [AppSettingsRecord]
    @Query(sort: \SteamGameRecord.name) private var games: [SteamGameRecord]
    @Query(sort: \LaunchRecord.startedAt, order: .reverse) private var launchRecords: [LaunchRecord]
    @State private var isWorking = false
    @State private var isShowingFreshStartConfirmation = false
    @State private var pendingRelocation: RelocationRequest?

    @ViewBuilder
    var body: some View {
        Group {
            if let preparationFailure {
                preparationFailureView(preparationFailure)
            } else if let reconnectRequest {
                reconnectView(reconnectRequest)
            } else {
                locationView
            }
        }
        .confirmationDialog(
            appState.localized(freshStartConfirmationTitle),
            isPresented: $isShowingFreshStartConfirmation,
            titleVisibility: .visible
        ) {
            Button(appState.localized("내부 위치에서 새로 설정")) {
                startFreshWithDefaultManagedStorage()
            }
            Button(appState.localized("취소"), role: .cancel) {}
        } message: {
            Text(appState.localized(freshStartConfirmationMessage))
        }
        .confirmationDialog(
            appState.localized("ForgePlay 앱 데이터를 새 위치로 옮길까요?"),
            isPresented: Binding(
                get: { pendingRelocation != nil },
                set: { if !$0 { pendingRelocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let request = pendingRelocation {
                Button(appState.localized("복사 후 이전 관리 데이터 삭제"), role: .destructive) {
                    pendingRelocation = nil
                    relocateManagedStorage(to: request.destination, bookmark: request.bookmark)
                }
            }
            Button(appState.localized("취소"), role: .cancel) {
                pendingRelocation = nil
            }
        } message: {
            if let request = pendingRelocation {
                Text(appState.localizedFormat(
                    "현재 위치: %@\n새 위치: %@\n복사와 검증이 끝나면 이전 위치에서 ForgePlay가 관리하는 데이터가 삭제됩니다. Steam 게임 라이브러리는 삭제하지 않습니다.",
                    request.source.path,
                    request.destination.path
                ))
            }
        }
    }

    private func reconnectView(_ request: ReconnectRequest) -> some View {
        let isLegacy = request.kind == .legacy
        let requiresDecision = request.requiresMigrationDecision
        let title = requiresDecision
            ? "기존 ForgePlay 데이터 처리"
            : (isLegacy ? "기존 ForgePlay 데이터 연결" : "ForgePlay 앱 데이터 접근 복구")
        let subtitle: String
        if requiresDecision {
            subtitle = "이전에 사용하던 ForgePlay 앱 데이터가 있습니다. 내부 저장소로 옮겨 계속 사용하거나, 이전 파일을 그대로 두고 새로 설정할 수 있습니다."
        } else if isLegacy {
            subtitle = "이전 프리픽스를 기본 내부 위치로 옮기려면 원래 폴더 접근 권한이 필요합니다."
        } else {
            subtitle = "사용자가 선택한 앱 데이터 폴더의 접근 권한을 macOS에서 다시 허용해야 합니다."
        }
        return GuidedSelectionView(
            title: title,
            subtitle: subtitle,
            primaryTitle: isWorking
                ? "처리 중"
                : (requiresDecision
                    ? "기존 데이터 내부로 옮기기"
                    : (request.requiresAuthorization
                        ? "macOS 폴더 선택기 열기"
                        : "다시 시도")),
            primaryIcon: requiresDecision
                ? "internaldrive"
                : (request.requiresAuthorization ? "folder.badge.plus" : "arrow.clockwise"),
            secondaryTitle: "내부 위치에서 새로 설정",
            secondaryIcon: "internaldrive",
            message: request.path,
            primaryDisabled: isWorking,
            secondaryDisabled: isWorking,
            secondaryDisabledReason: isWorking ? "현재 앱 데이터 작업이 끝난 뒤 다시 시도하세요." : nil,
            primaryAction: {
                if requiresDecision {
                    migratePersistedLegacyManagedStorage()
                } else if request.requiresAuthorization {
                    reconnectManagedStorage(request)
                } else {
                    retryManagedStoragePreparation()
                }
            },
            secondaryAction: { isShowingFreshStartConfirmation = true }
        )
    }

    private func preparationFailureView(_ failure: String) -> some View {
        let path = services.pathManager.rootURL?.path ??
            appState.selectedRootURL?.path ??
            settingsRecords.first?.selectedRootPath ??
            ((try? PathManager.defaultManagedRootURL())?.path ?? "")
        let detail = [failure, path]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        return GuidedSelectionView(
            title: "앱 데이터 위치를 준비하지 못했습니다.",
            subtitle: "폴더 재연결이 필요한 상태와 구분된 준비 오류입니다. 아래 오류와 실패 로그를 확인한 뒤 다시 시도하세요.",
            primaryTitle: isWorking ? "처리 중" : "다시 시도",
            primaryIcon: "arrow.clockwise",
            secondaryTitle: "내부 위치에서 새로 설정",
            secondaryIcon: "internaldrive",
            message: detail,
            primaryDisabled: isWorking,
            secondaryDisabled: isWorking,
            secondaryDisabledReason: isWorking ? "현재 앱 데이터 작업이 끝난 뒤 다시 시도하세요." : nil,
            primaryAction: retryManagedStoragePreparation,
            secondaryAction: { isShowingFreshStartConfirmation = true },
            tertiaryTitle: "실패 로그·Mac 사양 폴더 열기",
            tertiaryIcon: "folder",
            tertiaryDisabled: isWorking,
            tertiaryAction: openFailureEvidenceFolder
        )
    }

    @ViewBuilder
    private var locationView: some View {
        if isUsingDefaultManagedRoot {
            GuidedSelectionView(
                title: "ForgePlay 앱 데이터",
                subtitle: "Steam, Wine 프리픽스, 캐시와 로그는 기본적으로 Mac 내부 앱 데이터에 저장됩니다.",
                primaryTitle: "Finder에서 보기",
                primaryIcon: "folder",
                secondaryTitle: isWorking ? "이동 중" : "저장 위치 변경",
                secondaryIcon: "folder.badge.plus",
                message: appState.selectedRootURL?.path ?? "앱 데이터 위치를 준비하는 중입니다.",
                secondaryDisabled: isWorking,
                secondaryDisabledReason: isWorking ? "앱 데이터를 복사하고 설정을 갱신하는 중입니다." : nil,
                primaryAction: revealManagedStorage,
                secondaryAction: chooseManagedStorageDestination,
                tertiaryTitle: "기존 ForgePlay 데이터 연결",
                tertiaryIcon: "externaldrive.badge.plus",
                tertiaryDisabled: isWorking,
                tertiaryAction: chooseLegacyManagedStorageSource
            )
        } else {
            GuidedSelectionView(
                title: "ForgePlay 앱 데이터",
                subtitle: "사용자가 선택한 폴더에 Steam, Wine 프리픽스, 캐시와 로그를 저장하고 있습니다.",
                primaryTitle: "Finder에서 보기",
                primaryIcon: "folder",
                secondaryTitle: isWorking ? "이동 중" : "저장 위치 변경",
                secondaryIcon: "folder.badge.plus",
                message: appState.selectedRootURL?.path ?? "앱 데이터 위치를 준비하는 중입니다.",
                secondaryDisabled: isWorking,
                secondaryDisabledReason: isWorking ? "앱 데이터를 복사하고 설정을 갱신하는 중입니다." : nil,
                primaryAction: revealManagedStorage,
                secondaryAction: chooseManagedStorageDestination,
                tertiaryTitle: "기본 내부 위치로 복원",
                tertiaryIcon: "internaldrive",
                tertiaryDisabled: isWorking,
                tertiaryAction: restoreDefaultManagedStorage
            )
        }
    }

    private var reconnectRequest: ReconnectRequest? {
        let requiresRecovery: Bool
        let migrationDecisionPath: String?
        let requiresAuthorization: Bool
        switch services.managedStoragePreparationState {
        case .legacyMigrationDecisionRequired(let path):
            requiresRecovery = true
            migrationDecisionPath = path
            requiresAuthorization = false
        case .authorizationRequired:
            requiresRecovery = true
            migrationDecisionPath = nil
            requiresAuthorization = true
        case .failed:
            requiresRecovery = false
            migrationDecisionPath = nil
            requiresAuthorization = false
        default:
            requiresRecovery = appState.selectedRootURL == nil
            migrationDecisionPath = nil
            requiresAuthorization = requiresRecovery
        }
        guard requiresRecovery,
              let settings = settingsRecords.first,
              let path = (migrationDecisionPath ?? settings.selectedRootPath)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        let kind: ReconnectKind = settings.managedStorageLayoutVersion == ForgePlayManagedStorageLayout.currentVersion
            ? .current
            : .legacy
        return ReconnectRequest(
            kind: kind,
            path: path,
            requiresAuthorization: requiresAuthorization,
            requiresMigrationDecision: migrationDecisionPath != nil
        )
    }

    private var preparationFailure: String? {
        guard case .failed(let message) = services.managedStoragePreparationState else {
            return nil
        }
        return message
    }

    private var freshStartConfirmationTitle: String {
        isUsingDefaultManagedRoot
            ? "기본 내부 위치에서 설정 진행 상태를 다시 준비할까요?"
            : "기존 앱 데이터를 옮기지 않고 내부 위치에서 다시 설정할까요?"
    }

    private var freshStartConfirmationMessage: String {
        isUsingDefaultManagedRoot
            ? "현재 Steam 프리픽스와 로그 파일은 삭제하지 않습니다. 기본 내부 앱 데이터 위치를 다시 적용하고 설정 진행 기록만 초기화합니다."
            : "이전 외장 ForgePlay 폴더의 파일은 복사하거나 삭제하지 않습니다. 앱이 사용하는 위치를 기본 내부 앱 데이터로 바꾸고 설정 진행 기록만 초기화합니다."
    }

    private var isUsingDefaultManagedRoot: Bool {
        guard let defaultRoot = try? PathManager.defaultManagedRootURL().standardizedFileURL else {
            return false
        }
        let selectedRoot = services.pathManager.rootURL ??
            appState.selectedRootURL ??
            settingsRecords.first?.selectedRootPath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        guard let selectedRoot else { return true }
        return selectedRoot.standardizedFileURL.path == defaultRoot.path
    }

    private func revealManagedStorage() {
        guard let root = appState.selectedRootURL else {
            appState.setNotice(appState.localized("앱 데이터 위치를 아직 준비하지 못했습니다."), kind: .warning)
            return
        }
        _ = appState.revealInFinder(root)
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

        let root = services.pathManager.rootURL ??
            appState.selectedRootURL ??
            (try? PathManager.defaultManagedRootURL())
        if let logs = root?.appending(path: "Logs", directoryHint: .isDirectory),
           FileSystemItemPolicy.isNonSymlinkDirectory(logs),
           appState.openFileURL(logs) {
            return
        }
        if let root,
           FileSystemItemPolicy.isNonSymlinkDirectory(root),
           appState.openFileURL(root) {
            return
        }
        appState.setNotice(
            appState.localized("열 항목을 찾을 수 없습니다."),
            kind: .failure
        )
    }

    private func chooseManagedStorageDestination() {
        guard !isWorking, !services.isManagedStorageTransitionInProgress else { return }
        guard let selected = OpenPanelPresenter.chooseDirectory(
            title: appState.localized("ForgePlay 앱 데이터 위치 변경"),
            message: appState.localized("드라이브 최상위가 아닌 비어 있는 하위 폴더를 선택하세요. 실행 중인 Steam과 Wine을 종료한 뒤 현재 앱 데이터를 복사하며, Steam 게임 라이브러리 위치는 변경하지 않습니다."),
            prompt: appState.localized("이 위치로 이동"),
            initialDirectory: appState.selectedRootURL?.deletingLastPathComponent()
        ) else { return }

        let destination = selected.standardizedFileURL
        let bookmark = appState.bookmarkData(for: destination, role: .selectedRoot)
        guard !ForgePlaySandboxPolicy.isAppSandboxEnabled || bookmark != nil else { return }
        requestManagedStorageRelocation(to: destination, bookmark: bookmark)
    }

    private func restoreDefaultManagedStorage() {
        guard !isWorking, !services.isManagedStorageTransitionInProgress else { return }
        do {
            requestManagedStorageRelocation(to: try PathManager.defaultManagedRootURL(), bookmark: nil)
        } catch {
            appState.setError(error)
        }
    }

    private func requestManagedStorageRelocation(to destination: URL, bookmark: Data?) {
        guard let source = appState.selectedRootURL?.standardizedFileURL else {
            appState.setNotice(appState.localized("앱 데이터 위치를 아직 준비하지 못했습니다."), kind: .warning)
            return
        }
        let normalizedDestination = destination.standardizedFileURL
        guard source.path != normalizedDestination.path else {
            appState.setNotice(appState.localized("현재 사용 중인 앱 데이터 위치입니다."), kind: .warning)
            return
        }
        pendingRelocation = RelocationRequest(
            source: source,
            destination: normalizedDestination,
            bookmark: bookmark
        )
    }

    private func chooseLegacyManagedStorageSource() {
        guard !isWorking, !services.isManagedStorageTransitionInProgress else { return }
        guard let selected = OpenPanelPresenter.chooseDirectory(
            title: appState.localized("기존 ForgePlay 데이터 연결"),
            message: appState.localized("이전에 ForgePlay 앱 데이터로 사용한 폴더를 선택하세요."),
            prompt: appState.localized("다시 연결"),
            initialDirectory: URL(fileURLWithPath: "/Volumes", isDirectory: true),
            canCreateDirectories: false
        ) else { return }

        let source = selected.standardizedFileURL
        let bookmark = appState.bookmarkData(for: source, role: .steamLibrary)
        guard !ForgePlaySandboxPolicy.isAppSandboxEnabled || bookmark != nil else { return }
        importLegacyManagedStorage(from: source, bookmark: bookmark)
    }

    private func relocateManagedStorage(to destination: URL, bookmark: Data?) {
        isWorking = true
        let progressNotice = appState.setTask(appState.localized("ForgePlay 앱 데이터를 새 위치로 옮기는 중입니다."))
        Task {
            defer {
                isWorking = false
                if let progressNotice {
                    appState.clearNotice(id: progressNotice.id)
                }
            }
            do {
                let workflow = try await services.relocateManagedStorage(
                    to: destination,
                    destinationBookmark: bookmark,
                    appState: appState,
                    in: modelContext,
                    hasSteamReferences: !games.isEmpty,
                    launchRecords: launchRecords
                )
                let successMessage = appState.localizedFormat(
                    "앱 데이터 위치를 변경했습니다: %d개 항목, %@.",
                    workflow.storageActivation.copiedFiles,
                    appState.localizedByteCount(workflow.storageActivation.copiedBytes)
                )
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
                appState.setNotice(
                    DiagnosticWarningText.combined(
                        successMessage,
                        cleanupWarning,
                        postCommitWarning
                    ) ?? successMessage,
                    kind: cleanupWarning == nil && postCommitWarning == nil ? .success : .warning
                )
                dismiss()
            } catch {
                appState.setError(error)
            }
        }
    }

    private func reconnectManagedStorage(_ request: ReconnectRequest) {
        guard !isWorking else { return }
        let savedURL = URL(fileURLWithPath: request.path, isDirectory: true)
        let initialDirectory = FileManager.default.fileExists(atPath: savedURL.path)
            ? savedURL
            : savedURL.deletingLastPathComponent()
        guard let selected = OpenPanelPresenter.chooseDirectory(
            title: appState.localized("ForgePlay 앱 데이터 폴더 다시 연결"),
            message: appState.localized("이전에 ForgePlay 앱 데이터로 사용한 폴더를 선택하세요."),
            prompt: appState.localized("다시 연결"),
            initialDirectory: initialDirectory,
            canCreateDirectories: false
        ) else { return }

        let source = selected.standardizedFileURL
        do {
            let containsManagedData: Bool
            if request.kind == .current {
                containsManagedData = try services.storageMigrationService.hasCurrentManagedStorageMarker(at: source)
            } else {
                containsManagedData = try services.storageMigrationService.hasManagedData(at: source)
            }
            guard containsManagedData else {
                throw request.kind == .legacy
                    ? ManagedStorageActivationError.legacyRootDoesNotContainManagedData(source)
                    : ManagedStorageActivationError.managedRootDoesNotContainManagedData(source)
            }
            let bookmark = appState.bookmarkData(for: source, role: .selectedRoot)
            guard !ForgePlaySandboxPolicy.isAppSandboxEnabled || bookmark != nil else { return }
            let settings = try appState.loadOrCreateSettings(in: modelContext)
            if request.kind == .current {
                settings.selectedRootPath = source.path
            }
            settings.selectedRootBookmark = bookmark
            settings.updatedAt = Date()
            try modelContext.saveOrRollback()
            appState.setPersistedFileSelection(source, for: .selectedRoot)
        } catch {
            modelContext.rollback()
            appState.setError(error)
            return
        }

        isWorking = true
        let progressNotice = appState.setTask(appState.localized("ForgePlay 앱 데이터 접근을 복구하는 중입니다."))
        Task {
            defer {
                isWorking = false
                if let progressNotice {
                    appState.clearNotice(id: progressNotice.id)
                }
            }
            do {
                let workflow = try await services.refreshSetupWorkflow(
                    appState: appState,
                    in: modelContext,
                    hasSteamReferences: !games.isEmpty,
                    launchRecords: launchRecords
                )
                let message = workflow.storageActivation.didMigrateLegacyData
                    ? appState.localizedFormat(
                        "기존 프리픽스를 기본 내부 위치로 옮겼습니다: %d개 항목, %@.",
                        workflow.storageActivation.copiedFiles,
                        appState.localizedByteCount(workflow.storageActivation.copiedBytes)
                    )
                    : appState.localized("앱 데이터 폴더 접근을 복구했습니다.")
                appState.setNotice(message, kind: .success)
                dismiss()
            } catch {
                appState.setError(error)
            }
        }
    }

    private func retryManagedStoragePreparation() {
        guard !isWorking else { return }
        isWorking = true
        let progressNotice = appState.setTask(appState.localized("ForgePlay 앱 데이터 준비를 다시 시도하는 중입니다."))
        Task {
            defer {
                isWorking = false
                if let progressNotice {
                    appState.clearNotice(id: progressNotice.id)
                }
            }
            do {
                let workflow = try await services.refreshSetupWorkflow(
                    appState: appState,
                    in: modelContext,
                    hasSteamReferences: !games.isEmpty,
                    launchRecords: launchRecords
                )
                let message = workflow.storageActivation.didMigrateLegacyData
                    ? appState.localizedFormat(
                        "기존 프리픽스를 기본 내부 위치로 옮겼습니다: %d개 항목, %@.",
                        workflow.storageActivation.copiedFiles,
                        appState.localizedByteCount(workflow.storageActivation.copiedBytes)
                    )
                    : appState.localized("앱 데이터 준비를 완료했습니다.")
                appState.setNotice(message, kind: .success)
                dismiss()
            } catch {
                appState.setError(error)
            }
        }
    }

    private func migratePersistedLegacyManagedStorage() {
        guard !isWorking else { return }
        isWorking = true
        let progressNotice = appState.setTask(appState.localized("ForgePlay 앱 데이터를 새 위치로 옮기는 중입니다."))
        Task {
            defer {
                isWorking = false
                if let progressNotice {
                    appState.clearNotice(id: progressNotice.id)
                }
            }
            do {
                let workflow = try await services.migratePersistedLegacyManagedStorage(
                    appState: appState,
                    in: modelContext,
                    hasSteamReferences: !games.isEmpty,
                    launchRecords: launchRecords
                )
                appState.setNotice(
                    appState.localizedFormat(
                        "기존 프리픽스를 기본 내부 위치로 옮겼습니다: %d개 항목, %@.",
                        workflow.storageActivation.copiedFiles,
                        appState.localizedByteCount(workflow.storageActivation.copiedBytes)
                    ),
                    kind: .success
                )
                dismiss()
            } catch {
                appState.setError(error)
            }
        }
    }

    private func startFreshWithDefaultManagedStorage() {
        guard !isWorking else { return }
        let startedFromDefaultManagedRoot = isUsingDefaultManagedRoot
        isWorking = true
        let progressNotice = appState.setTask(appState.localized("기본 내부 앱 데이터에서 설정을 다시 준비하는 중입니다."))
        Task {
            defer {
                isWorking = false
                if let progressNotice {
                    appState.clearNotice(id: progressNotice.id)
                }
            }
            do {
                _ = try await services.startFreshWithDefaultManagedStorage(
                    appState: appState,
                    in: modelContext
                )
                appState.setNotice(
                    appState.localized(
                        startedFromDefaultManagedRoot
                            ? "기본 내부 앱 데이터는 유지하고 설정 진행 기록을 다시 시작합니다."
                            : "이전 외장 앱 데이터는 그대로 두고 기본 내부 위치에서 설정을 다시 시작합니다."
                    ),
                    kind: .success
                )
                dismiss()
            } catch {
                appState.setError(error)
            }
        }
    }

    private func importLegacyManagedStorage(from source: URL, bookmark: Data?) {
        isWorking = true
        let progressNotice = appState.setTask(appState.localized("ForgePlay 앱 데이터 접근을 복구하는 중입니다."))
        Task {
            defer {
                isWorking = false
                if let progressNotice {
                    appState.clearNotice(id: progressNotice.id)
                }
            }
            do {
                let workflow = try await services.importLegacyManagedStorage(
                    from: source,
                    sourceBookmark: bookmark,
                    appState: appState,
                    in: modelContext,
                    hasSteamReferences: !games.isEmpty,
                    launchRecords: launchRecords
                )
                appState.setNotice(
                    appState.localizedFormat(
                        "기존 프리픽스를 기본 내부 위치로 옮겼습니다: %d개 항목, %@.",
                        workflow.storageActivation.copiedFiles,
                        appState.localizedByteCount(workflow.storageActivation.copiedBytes)
                    ),
                    kind: .success
                )
                dismiss()
            } catch {
                appState.setError(error)
            }
        }
    }
}
