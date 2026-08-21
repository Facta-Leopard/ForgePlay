import Foundation
import SwiftData

@MainActor
struct SteamLaunchRecordLifecycle {
    var modelContext: ModelContext
    var appState: AppState
    var services: AppServices

    func saveLaunchResult(_ result: ProcessRunResult, launchRecord: LaunchRecord) -> String? {
        do {
            try modelContext.saveSteamLaunchResult(result, for: launchRecord)
        } catch {
            modelContext.rollback()
            return appState.localizedFormat("실행 기록을 저장하지 못했습니다: %@", forgePlayTechnicalErrorSummary(error))
        }
        scheduleCompletedHistoryMaintenance()
        return nil
    }

    func handleLaunchFailure(
        _ launchRecord: LaunchRecord?,
        error: Error,
        surfaceIdentifier: String
    ) {
        let evidenceResolution: FailureDiagnosticEvidenceResolution?
        let evidenceCaptureWarning: String?
        let selectedSteamReference = appState.selectedSteamReference
        let additionalSensitivePaths = DiagnosticPathRedactionPolicy.sensitivePaths(
            rootURL: appState.selectedRootURL ?? services.pathManager.rootURL,
            selectedSteamReference: selectedSteamReference,
            runtimeExecutable: appState.runtimeExecutableURL
        )
        let additionalSensitiveTerms = DiagnosticPathRedactionPolicy.sensitiveTerms(
            selectedSteamReference: selectedSteamReference
        )
        do {
            evidenceResolution = try services.failureDiagnosticEvidenceService.ensureEvidence(
                for: error,
                operationIdentifier: "steam.launch",
                surfaceIdentifier: surfaceIdentifier,
                additionalSensitivePaths: additionalSensitivePaths,
                additionalSensitiveTerms: additionalSensitiveTerms
            )
            evidenceCaptureWarning = nil
            appState.lastFailureEvidenceURL = evidenceResolution?.url
        } catch {
            evidenceResolution = nil
            evidenceCaptureWarning = appState.localizedFormat(
                "실행 실패 기록을 저장하지 못했습니다: %@",
                forgePlayTechnicalErrorSummary(error)
            )
        }

        let standaloneEvidenceURL = evidenceResolution.flatMap { resolution -> URL? in
            switch resolution {
            case .capturedFailure(let url):
                url
            case .existingProcessEvidence:
                nil
            }
        }
        let launchPersistenceWarning = launchRecord.flatMap {
            closeAsFailed($0, error: error, diagnosticLogURL: standaloneEvidenceURL)
        }
        presentLaunchFailure(
            error,
            evidenceResolution: evidenceResolution,
            warning: DiagnosticWarningText.combined(
                evidenceCaptureWarning,
                launchPersistenceWarning
            )
        )
    }

    private func closeAsFailed(
        _ launchRecord: LaunchRecord,
        error: Error,
        diagnosticLogURL: URL?
    ) -> String? {
        let causalError = (error as? ProcessExecutionEvidenceError)?.underlyingError ?? error
        let bridgedError = causalError as NSError
        do {
            if let result = diagnosticProcessRunResult(from: error) {
                try modelContext.markSteamLaunchFailed(
                    launchRecord,
                    with: result,
                    failureDomain: bridgedError.domain,
                    failureCode: bridgedError.code,
                    failureSummary: forgePlayTechnicalErrorSummary(causalError)
                )
            } else {
                try modelContext.markSteamLaunchFailedWithoutResult(
                    launchRecord,
                    failureDomain: bridgedError.domain,
                    failureCode: bridgedError.code,
                    failureSummary: forgePlayTechnicalErrorSummary(causalError),
                    diagnosticLogPath: diagnosticLogURL?.path
                )
            }
        } catch {
            modelContext.rollback()
            return appState.localizedFormat(
                "실행 실패 기록을 저장하지 못했습니다: %@",
                forgePlayTechnicalErrorSummary(error)
            )
        }
        scheduleCompletedHistoryMaintenance()
        return nil
    }

    private func presentLaunchFailure(
        _ error: Error,
        evidenceResolution: FailureDiagnosticEvidenceResolution?,
        warning: String?
    ) {
        appState.setError(error, captureFailureEvidence: false)
        guard evidenceResolution != nil || warning != nil else { return }
        let currentNotice = appState.currentNotice
        let message = DiagnosticWarningText.combined(
            currentNotice?.message ?? appState.localizedError(error),
            warning
        ) ?? appState.localizedError(error)
        appState.setNotice(
            message,
            kind: .failure,
            logURL: currentNotice?.logURL ?? evidenceResolution?.url,
            captureFailureEvidence: false
        )
    }

    func confirmSteamUIRendered(_ launchRecord: LaunchRecord) -> AppNotice? {
        confirmSteamUISurface(.unknown, launchRecord: launchRecord)
    }

    func confirmSteamUISurface(
        _ surface: SteamUISurface,
        launchRecord: LaunchRecord
    ) -> AppNotice? {
        guard canConfirmSteamUI(for: launchRecord) else {
            return appState.setNotice(
                appState.localized("현재 ForgePlay 세션과 Steam 프리픽스에서 가장 최근에 시작한 Steam 실행만 화면 상태를 기록할 수 있습니다."),
                kind: .warning
            )
        }
        do {
            try modelContext.markSteamUISurface(surface, for: launchRecord)
            scheduleCompletedHistoryMaintenance()
            let messageKey = switch surface {
            case .signIn:
                "Steam 로그인 화면 확인을 기록했습니다. 로그인을 완료한 뒤 라이브러리 화면도 확인하세요."
            case .steamGuard:
                "Steam Guard 화면 확인을 기록했습니다. 인증을 완료한 뒤 라이브러리 화면도 확인하세요."
            case .library:
                "Steam 라이브러리 화면 확인을 기록했습니다."
            case .unknown:
                "Steam UI 렌더링 확인을 기록했습니다."
            }
            let noticeKind: AppNoticeKind = surface == .library ? .success : .warning
            return appState.setNotice(appState.localized(messageKey), kind: noticeKind)
        } catch {
            modelContext.rollback()
            appState.setNotice(
                appState.localizedFormat("Steam UI 확인 기록을 저장하지 못했습니다: %@", forgePlayTechnicalErrorSummary(error)),
                kind: .warning
            )
            return nil
        }
    }

    func markSteamUIBlackScreen(_ launchRecord: LaunchRecord) -> AppNotice? {
        guard canConfirmSteamUI(for: launchRecord) else {
            return appState.setNotice(
                appState.localized("현재 ForgePlay 세션과 Steam 프리픽스에서 가장 최근에 시작한 Steam 실행만 화면 상태를 기록할 수 있습니다."),
                kind: .warning
            )
        }
        do {
            try modelContext.markSteamUIBlackScreenSuspected(launchRecord)
            scheduleCompletedHistoryMaintenance()
            return appState.setNotice(appState.localized("Steam 검은 화면 상태를 기록했습니다."), kind: .warning)
        } catch {
            modelContext.rollback()
            appState.setNotice(
                appState.localizedFormat("Steam UI 확인 기록을 저장하지 못했습니다: %@", forgePlayTechnicalErrorSummary(error)),
                kind: .warning
            )
            return nil
        }
    }

    func canConfirmSteamUI(for launchRecord: LaunchRecord) -> Bool {
        let environmentIdentity = services.steamPrefixReadinessResolver
            .currentSteamEnvironmentIdentity()
        guard launchRecord.commandKind == "launchSteam",
              launchRecord.prefixId == PrefixIdentifier.steamShared,
              launchRecord.hostAppSessionID == services.appSessionID,
              isEligibleForManualUIVerification(launchRecord),
              environmentIdentity.isEstablished,
              launchRecordBelongsToEnvironment(
                launchRecord,
                environmentIdentity: environmentIdentity
              ),
              let latest = try? services.steamLaunchReadinessRepository
                .latestDisplayRecord(
                    in: modelContext,
                    environmentIdentity: environmentIdentity,
                    currentAppSessionID: services.appSessionID
                ) else {
            return false
        }
        return latest.id == launchRecord.id
    }

    private func launchRecordBelongsToEnvironment(
        _ launchRecord: LaunchRecord,
        environmentIdentity: SteamEnvironmentIdentity
    ) -> Bool {
        if let generationID = environmentIdentity.generationID {
            return launchRecord.environmentGenerationID == generationID
        }
        guard let createdAt = environmentIdentity.createdAt else { return false }
        return launchRecord.startedAt >= createdAt
    }

    private func scheduleCompletedHistoryMaintenance() {
        _ = services.steamLaunchHistoryMaintenanceScheduler.schedule(
            modelContainer: modelContext.container,
            environmentIdentity: services.steamPrefixReadinessResolver
                .currentSteamEnvironmentIdentity(),
            currentAppSessionID: services.appSessionID
        ) { [weak appState] error in
            appState?.setNotice(
                appState?.localizedFormat(
                    "실행 결과는 저장했지만 오래된 실행 기록을 정리하지 못했습니다: %@",
                    forgePlayTechnicalErrorSummary(error)
                ) ?? forgePlayTechnicalErrorSummary(error),
                kind: .warning
            )
        }
    }

    private func isEligibleForManualUIVerification(_ launchRecord: LaunchRecord) -> Bool {
        switch launchRecord.steamUIVerificationState {
        case .launchedButUnverified:
            true
        case .rendered:
            launchRecord.steamUISurface != .library
        case .notRun, .blackScreenSuspected, .failed:
            false
        }
    }
}
