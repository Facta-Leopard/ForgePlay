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
        var authenticatedRuntimeManifest: RuntimeManifest?
        var runtimeCapability: WindowsRuntimeCapability?
    }

    private struct CompletedRuntimeSnapshot {
        var key: SystemCheckRequestKey
        var authenticatedRuntimeManifest: RuntimeManifest?
        var runtimeCapability: WindowsRuntimeCapability?
    }

    private(set) var isSystemCheckInProgress = false
    @ObservationIgnored private var activeSystemCheck: (
        key: SystemCheckRequestKey,
        generation: Int,
        task: Task<SystemCheckRunOutcome, Never>
    )?
    @ObservationIgnored private var systemCheckGeneration = 0
    @ObservationIgnored private var completedRuntimeSnapshot:
        CompletedRuntimeSnapshot?

    private let systemCheckService: SystemCheckService
    private let readinessResolver: SteamPrefixReadinessResolver

    init(
        systemCheckService: SystemCheckService,
        readinessResolver: SteamPrefixReadinessResolver
    ) {
        self.systemCheckService = systemCheckService
        self.readinessResolver = readinessResolver
    }

    func computeRefresh(
        storageActivation: ManagedStorageActivationResult,
        runtimeExecutable: URL?,
        rendererPolicySelection: SteamRendererPolicySelection,
        videoMemorySelection: SteamVideoMemorySelection,
        hasSteamReferences: Bool,
        launchReadinessProjection: SteamLaunchReadinessProjection
    ) async throws -> SetupWorkflowRefreshResult {
        let outcome = await runSystemChecks(
            rootURL: storageActivation.rootURL,
            runtimeExecutable: runtimeExecutable
        )
        try Task.checkCancellation()
        guard outcome.generation == systemCheckGeneration else {
            throw CancellationError()
        }
        let readiness = computeReadiness(
            hasSteamReferences: hasSteamReferences,
            launchReadinessProjection: launchReadinessProjection,
            runtimeExecutable: runtimeExecutable,
            managedRootURL: storageActivation.rootURL,
            authenticatedRuntimeManifest:
                outcome.authenticatedRuntimeManifest,
            runtimeCapability: outcome.runtimeCapability,
            rendererPolicySelection: rendererPolicySelection,
            videoMemorySelection: videoMemorySelection
        )
        return SetupWorkflowRefreshResult(
            storageActivation: storageActivation,
            checks: outcome.checks,
            readiness: readiness
        )
    }

    func computeReadiness(
        hasSteamReferences: Bool,
        launchReadinessProjection: SteamLaunchReadinessProjection,
        runtimeExecutable: URL?,
        managedRootURL: URL? = nil,
        authenticatedRuntimeManifest: RuntimeManifest? = nil,
        runtimeCapability: WindowsRuntimeCapability? = nil,
        rendererPolicySelection: SteamRendererPolicySelection,
        videoMemorySelection: SteamVideoMemorySelection
    ) -> SetupReadiness {
        let snapshotKey = SystemCheckRequestKey(
            rootPath: managedRootURL?.standardizedFileURL.path,
            runnerPath: runtimeExecutable?.standardizedFileURL.path
        )
        let matchingCompletedSnapshot = completedRuntimeSnapshot.flatMap {
            $0.key == snapshotKey ? $0 : nil
        }
        let resolvedManifest = authenticatedRuntimeManifest ??
            matchingCompletedSnapshot?.authenticatedRuntimeManifest
        let resolvedCapability = runtimeCapability ??
            matchingCompletedSnapshot?.runtimeCapability
        return readinessResolver.resolve(
            hasSteamReferences: hasSteamReferences,
            runtimeExecutable: runtimeExecutable,
            runtimeManifest: resolvedManifest,
            runtimeCapability: resolvedCapability,
            rendererPolicySelection: rendererPolicySelection,
            videoMemorySelection: videoMemorySelection
        )
        .withSteamLaunchReadinessProjection(launchReadinessProjection)
    }

    func invalidateSystemCheck() {
        systemCheckGeneration += 1
        activeSystemCheck?.task.cancel()
        activeSystemCheck = nil
        isSystemCheckInProgress = false
    }

    func invalidateRuntimeCapabilitySnapshot() async {
        invalidateSystemCheck()
        completedRuntimeSnapshot = nil
        await systemCheckService.invalidateRuntimeCapabilitySnapshots()
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
                let result = await activeSystemCheck.task.value
                return SystemCheckOutcome(
                    generation: activeSystemCheck.generation,
                    checks: result.checks,
                    authenticatedRuntimeManifest:
                        result.authenticatedRuntimeManifest,
                    runtimeCapability: result.runtimeCapability
                )
            }
            activeSystemCheck.task.cancel()
            self.activeSystemCheck = nil
        }

        systemCheckGeneration += 1
        let generation = systemCheckGeneration
        isSystemCheckInProgress = true
        let task = Task { @MainActor [systemCheckService] in
            await systemCheckService.runChecksWithRuntimeContext(
                rootURL: rootURL,
                runtimeExecutable: runtimeExecutable
            )
        }
        activeSystemCheck = (key, generation, task)
        let result = await task.value
        if activeSystemCheck?.generation == generation,
           systemCheckGeneration == generation {
            activeSystemCheck = nil
            isSystemCheckInProgress = false
            completedRuntimeSnapshot = CompletedRuntimeSnapshot(
                key: key,
                authenticatedRuntimeManifest:
                    result.authenticatedRuntimeManifest,
                runtimeCapability: result.runtimeCapability
            )
        }
        return SystemCheckOutcome(
            generation: generation,
            checks: result.checks,
            authenticatedRuntimeManifest:
                result.authenticatedRuntimeManifest,
            runtimeCapability: result.runtimeCapability
        )
    }
}
