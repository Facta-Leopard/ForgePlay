import Foundation
import Observation

struct SetupWorkflowRefreshResult: Hashable {
    var storageActivation: ManagedStorageActivationResult
    var checks: [SystemCheckResult]
    var readiness: SetupReadiness
}

@MainActor
@Observable
final class SetupWorkflowCoordinator {
    private struct SystemCheckRequestKey: Hashable {
        var rootPath: String?
        var runnerPath: String?
    }

    private struct SystemCheckOutcome {
        var generation: Int
        var checks: [SystemCheckResult]
    }

    private(set) var isSystemCheckInProgress = false
    @ObservationIgnored private var activeSystemCheck: (
        key: SystemCheckRequestKey,
        generation: Int,
        task: Task<[SystemCheckResult], Never>
    )?
    @ObservationIgnored private var systemCheckGeneration = 0

    private let systemCheckService: SystemCheckService
    private let readinessResolver: SteamPrefixReadinessResolver
    private let appSessionID: String

    init(
        systemCheckService: SystemCheckService,
        readinessResolver: SteamPrefixReadinessResolver,
        appSessionID: String
    ) {
        self.systemCheckService = systemCheckService
        self.readinessResolver = readinessResolver
        self.appSessionID = appSessionID
    }

    func refresh(
        storageActivation: ManagedStorageActivationResult,
        appState: AppState,
        hasSteamReferences: Bool,
        launchRecords: [LaunchRecord]
    ) async -> SetupWorkflowRefreshResult {
        let outcome = await runSystemChecks(
            rootURL: storageActivation.rootURL,
            runtimeExecutable: appState.runtimeExecutableURL
        )
        guard outcome.generation == systemCheckGeneration, !Task.isCancelled else {
            return SetupWorkflowRefreshResult(
                storageActivation: storageActivation,
                checks: appState.latestChecks,
                readiness: appState.setupReadiness
            )
        }
        appState.latestChecks = outcome.checks
        let readiness = synchronizeReadiness(
            appState: appState,
            hasSteamReferences: hasSteamReferences,
            launchRecords: launchRecords
        )
        return SetupWorkflowRefreshResult(
            storageActivation: storageActivation,
            checks: outcome.checks,
            readiness: readiness
        )
    }

    @discardableResult
    func synchronizeReadiness(
        appState: AppState,
        hasSteamReferences: Bool,
        launchRecords: [LaunchRecord]
    ) -> SetupReadiness {
        let readiness = readinessResolver.resolve(
            hasSteamReferences: hasSteamReferences,
            runtimeExecutable: appState.runtimeExecutableURL,
            rendererPolicySelection: appState.steamRendererPolicySelection,
            videoMemorySelection: appState.steamVideoMemorySelection
        )
        .withSteamLaunchRecords(launchRecords, currentAppSessionID: appSessionID)
        appState.updateSetupStage(readiness: readiness)
        return readiness
    }

    func invalidateSystemCheck() {
        systemCheckGeneration += 1
        activeSystemCheck?.task.cancel()
        activeSystemCheck = nil
        isSystemCheckInProgress = false
    }

    private func runSystemChecks(
        rootURL: URL?,
        runtimeExecutable: URL?
    ) async -> SystemCheckOutcome {
        let key = SystemCheckRequestKey(
            rootPath: rootURL?.standardizedFileURL.path,
            runnerPath: runtimeExecutable?.standardizedFileURL.path
        )
        if let activeSystemCheck {
            if activeSystemCheck.key == key {
                return SystemCheckOutcome(
                    generation: activeSystemCheck.generation,
                    checks: await activeSystemCheck.task.value
                )
            }
            activeSystemCheck.task.cancel()
            self.activeSystemCheck = nil
        }

        systemCheckGeneration += 1
        let generation = systemCheckGeneration
        isSystemCheckInProgress = true
        let task = Task { @MainActor [systemCheckService] in
            await systemCheckService.runChecks(
                rootURL: rootURL,
                runtimeExecutable: runtimeExecutable
            )
        }
        activeSystemCheck = (key, generation, task)
        let checks = await task.value
        if activeSystemCheck?.generation == generation,
           systemCheckGeneration == generation {
            activeSystemCheck = nil
            isSystemCheckInProgress = false
        }
        return SystemCheckOutcome(generation: generation, checks: checks)
    }
}
