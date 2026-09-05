import CryptoKit
import Darwin
import Foundation

struct SteamManagerCompatibilityLaunchContextV1: Hashable, Sendable {
    let runtimeExecutableBookmark: Data
    let steamClientLanguage: SteamClientLanguage
    let steamArguments: [String]?
    let reservedRoots: [URL]

    init(
        runtimeExecutableBookmark: Data,
        steamClientLanguage: SteamClientLanguage,
        steamArguments: [String]? = nil,
        reservedRoots: [URL] = []
    ) throws {
        guard !runtimeExecutableBookmark.isEmpty,
              runtimeExecutableBookmark.count <= 1_048_576 else {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "runtime-executable-authorization",
                value: "bookmark-size"
            )
        }
        self.runtimeExecutableBookmark = runtimeExecutableBookmark
        self.steamClientLanguage = steamClientLanguage
        self.steamArguments = steamArguments
        self.reservedRoots = reservedRoots
    }
}

struct SteamManagerCompatibilityLaunchProjectionV1: Hashable, Sendable {
    let rendererSelection: SteamRendererPolicySelection
    let frameGenerationConfiguration: FrameGenerationConfiguration
    let networkSelection: SteamNetworkCompatibilitySelection
    let audioInputSelection: SteamAudioInputSelection
    let synchronizationSelection: WineSynchronizationSelection
    let videoMemorySelection: SteamVideoMemorySelection
    let videoMemorySizeMB: Int
    let gameModePolicy: SteamGameModeLaunchPolicy
    let fpsCursorPolicy: FPSCursorCapturePolicy
    let controllerPolicy: ControllerCompatibilityPolicy
    let keyboardMapping: KeyboardMappingPreference
    let authorizedManifestRootDigest: String

    init(
        rendererSelection: SteamRendererPolicySelection,
        frameGenerationConfiguration: FrameGenerationConfiguration = .off,
        networkSelection: SteamNetworkCompatibilitySelection,
        audioInputSelection: SteamAudioInputSelection,
        synchronizationSelection: WineSynchronizationSelection,
        videoMemorySelection: SteamVideoMemorySelection,
        videoMemorySizeMB: Int,
        gameModePolicy: SteamGameModeLaunchPolicy,
        fpsCursorPolicy: FPSCursorCapturePolicy,
        controllerPolicy: ControllerCompatibilityPolicy,
        keyboardMapping: KeyboardMappingPreference,
        authorizedManifestRootDigest: String
    ) {
        self.rendererSelection = rendererSelection
        self.frameGenerationConfiguration = frameGenerationConfiguration
        self.networkSelection = networkSelection
        self.audioInputSelection = audioInputSelection
        self.synchronizationSelection = synchronizationSelection
        self.videoMemorySelection = videoMemorySelection
        self.videoMemorySizeMB = videoMemorySizeMB
        self.gameModePolicy = gameModePolicy
        self.fpsCursorPolicy = fpsCursorPolicy
        self.controllerPolicy = controllerPolicy
        self.keyboardMapping = keyboardMapping
        self.authorizedManifestRootDigest = authorizedManifestRootDigest
    }
}

enum SteamManagerCompatibilityLaunchRequestMapperV1 {
    static func projection(
        for request: ResolvedCompatibilityLaunchRequestV1
    ) throws -> SteamManagerCompatibilityLaunchProjectionV1 {
        try request.validate()
        let snapshot = request.snapshot

        let rendererSelection: SteamRendererPolicySelection
        switch snapshot.graphicsBackend.value.rawValue {
        case "d3dMetal": rendererSelection = .d3dMetal
        case "d3dMetalNVIDIA": rendererSelection = .d3dMetalNVIDIA
        case "dxmt": rendererSelection = .dxmt
        case "d9vk": rendererSelection = .d9vk
        case "dxvk": rendererSelection = .vulkan
        default:
            throw unsupported(
                category: "graphics-backend",
                value: snapshot.graphicsBackend.value.rawValue
            )
        }
        try snapshot.frameGenerationConfiguration.value.validate(
            isSupportedRenderer:
                rendererSelection.supportsD3DMetalFrameGeneration
        )

        let networkSelection: SteamNetworkCompatibilitySelection
        switch snapshot.networkPolicy.value.rawValue {
        case "standard": networkSelection = .standard
        case "wifi-identity": networkSelection = .wifiIdentity
        case "ethernet-identity": networkSelection = .ethernetIdentity
        default:
            throw unsupported(
                category: "network-policy",
                value: snapshot.networkPolicy.value.rawValue
            )
        }

        let audioInputSelection: SteamAudioInputSelection
        switch snapshot.audioInputPolicy.value.rawValue {
        case "disabled": audioInputSelection = .disabled
        case "enabled": audioInputSelection = .enabled
        default:
            throw unsupported(
                category: "audio-input-policy",
                value: snapshot.audioInputPolicy.value.rawValue
            )
        }

        guard snapshot.synchronizationPolicy.value.rawValue == "automatic" else {
            throw unsupported(
                category: "synchronization-policy",
                value: snapshot.synchronizationPolicy.value.rawValue
            )
        }

        let videoMemorySelection: SteamVideoMemorySelection
        switch snapshot.videoMemoryPolicy.value.rawValue {
        case "automatic": videoMemorySelection = .automatic
        case "gb2": videoMemorySelection = .gb2
        case "gb4": videoMemorySelection = .gb4
        case "gb8": videoMemorySelection = .gb8
        case "gb12": videoMemorySelection = .gb12
        case "gb16": videoMemorySelection = .gb16
        default:
            throw unsupported(
                category: "video-memory-policy",
                value: snapshot.videoMemoryPolicy.value.rawValue
            )
        }

        return SteamManagerCompatibilityLaunchProjectionV1(
            rendererSelection: rendererSelection,
            frameGenerationConfiguration: snapshot.frameGenerationConfiguration.value,
            networkSelection: networkSelection,
            audioInputSelection: audioInputSelection,
            synchronizationSelection: .automatic,
            videoMemorySelection: videoMemorySelection,
            videoMemorySizeMB: videoMemorySelection.resolvedSizeMB(),
            gameModePolicy: snapshot.gameModeEnabled.value
                ? .experimentalRequiredHost
                : .standard,
            fpsCursorPolicy: snapshot.fpsCursorPolicy.value,
            controllerPolicy: snapshot.controllerPolicy.value,
            keyboardMapping: snapshot.keyboardMapping.value,
            authorizedManifestRootDigest:
                request.manifestRootAuthorization.authorizationDigest
        )
    }

    private static func unsupported(
        category: String,
        value: String
    ) -> SteamCompatibilityLaunchProfileErrorV1 {
        .unsupportedCapability(category: category, value: value)
    }
}

enum SteamManagerCompatibilityControlBoundaryV1 {
    static func requireConsumableRequest(
        _ request: ResolvedCompatibilityLaunchRequestV1
    ) throws {
        try request.validate()
        _ = try KeyboardMappingPreference(
            preset: request.snapshot.keyboardMapping.value.preset,
            customPermutation:
                request.snapshot.keyboardMapping.value.customPermutation
        )
    }
}

@MainActor
final class SteamManagerCompatibilityLaunchRuntimeProviderV1:
    CompatibilityLaunchRuntimeProviderV1,
    @unchecked Sendable
{
    struct CompatibilityRestorationRetryMachineV1: Sendable {
        enum State: Equatable, Sendable {
            case active
            case waiting(attempt: Int)
            case restoring(attempt: Int)
            case retrying(attempt: Int, diagnostic: String)
            case restored
        }

        private(set) var attempt = 0
        private(set) var state: State = .active

        mutating func beginAttempt() -> Int {
            attempt += 1
            state = .waiting(attempt: attempt)
            return attempt
        }

        mutating func beginRestoration() {
            state = .restoring(attempt: attempt)
        }

        mutating func recordFailure(_ diagnostic: String) -> Int {
            state = .retrying(attempt: attempt, diagnostic: diagnostic)
            let exponent = min(max(attempt - 1, 0), 6)
            return min(60, 1 << exponent)
        }

        mutating func recordVerifiedRestoration() {
            state = .restored
        }

        var permitsRelease: Bool { state == .restored }
    }

    struct PostLaunchCleanupRetryPolicy: Sendable {
        static func delayBeforeAttemptSeconds(_ attempt: Int) -> Int? {
            guard attempt > 0 else { return nil }
            guard attempt > 1 else { return 0 }
            let exponent = min(attempt - 2, 6)
            return min(60, 1 << exponent)
        }
    }

    private final class ActiveSession: SteamCompatibilityBackgroundWorkOwner {
        let projection: SteamManagerCompatibilityLaunchProjectionV1
        let receipt: CompatibilityLaunchApplicationReceiptV1
        let prefixBinding: SteamCompatibilityPrefixBinding
        let runtimeScope: SecurityScopedCompatibilityRuntimeExecutableScopeV1
        let manifestScope: SecurityScopedCompatibilityManifestRootScopeV1
        let gameRootLease: CompatibilityGameRootLifetimeLeaseV1
        let prefixLease: SteamCompatibilityPrefixSessionLease
        let persistentPrefixSnapshot: SteamCompatibilityPersistentPrefixSnapshot
        var automaticCompletionTask: Task<Void, Never>?
        var automaticCompletionState:
            SteamCompatibilityBackgroundWorkCompletionState?
        var supersededAutomaticCompletionStates:
            [SteamCompatibilityBackgroundWorkCompletionState] = []
        var cancelledBackgroundWorkCompletionStates:
            [SteamCompatibilityBackgroundWorkCompletionState] = []
        let completionRendezvous = CompatibilityCompletionRendezvous<
            CompatibilityLaunchApplicationReceiptV1
        >()
        var completionOwnershipPolicy = CompletionOwnershipPolicyV1()
        var restorationMachine = CompatibilityRestorationRetryMachineV1()

        init(
            projection: SteamManagerCompatibilityLaunchProjectionV1,
            receipt: CompatibilityLaunchApplicationReceiptV1,
            prefixBinding: SteamCompatibilityPrefixBinding,
            runtimeScope: SecurityScopedCompatibilityRuntimeExecutableScopeV1,
            manifestScope: SecurityScopedCompatibilityManifestRootScopeV1,
            gameRootLease: CompatibilityGameRootLifetimeLeaseV1,
            prefixLease: SteamCompatibilityPrefixSessionLease,
            persistentPrefixSnapshot: SteamCompatibilityPersistentPrefixSnapshot
        ) {
            self.projection = projection
            self.receipt = receipt
            self.prefixBinding = prefixBinding
            self.runtimeScope = runtimeScope
            self.manifestScope = manifestScope
            self.gameRootLease = gameRootLease
            self.prefixLease = prefixLease
            self.persistentPrefixSnapshot = persistentPrefixSnapshot
        }

        deinit {
            automaticCompletionTask?.cancel()
        }

        func cancelCompatibilityBackgroundWork()
            -> [SteamCompatibilityBackgroundWorkCompletionState]
        {
            var completionStates = cancelledBackgroundWorkCompletionStates
                .filter { !$0.isCompleted }
            completionStates.append(contentsOf:
                supersededAutomaticCompletionStates
                .filter { !$0.isCompleted }
            )
            supersededAutomaticCompletionStates.removeAll(
                keepingCapacity: false
            )
            if let automaticCompletionTask {
                self.automaticCompletionTask = nil
                automaticCompletionTask.cancel()
                if let automaticCompletionState {
                    completionStates.append(automaticCompletionState)
                }
                self.automaticCompletionState = nil
            }
            if let completionState = completionRendezvous.cancelActiveAttempt() {
                completionStates.append(completionState)
            }
            cancelledBackgroundWorkCompletionStates =
                Self.deduplicated(completionStates)
            return cancelledBackgroundWorkCompletionStates
        }

        private static func deduplicated(
            _ states: [SteamCompatibilityBackgroundWorkCompletionState]
        ) -> [SteamCompatibilityBackgroundWorkCompletionState] {
            var seen = Set<ObjectIdentifier>()
            return states.filter {
                seen.insert(ObjectIdentifier($0)).inserted
            }
        }
    }

    struct CompletionOwnershipPolicyV1: Sendable {
        enum Caller: Equatable, Sendable {
            case automatic
            case manual
            case applicationTermination
        }

        enum FailureDisposition: Equatable, Sendable {
            case keepRetainedForExistingRecovery
            case retryTerminationStopFirst(remainingRetries: Int)
            case rearmAutomaticRecovery
        }

        private(set) var applicationTerminationRequested = false

        mutating func registerApplicationTerminationRequest() {
            applicationTerminationRequested = true
        }

        func requiresRuntimeStopFirst(
            requestedByAttemptOwner: Bool
        ) -> Bool {
            requestedByAttemptOwner || applicationTerminationRequested
        }

        func failureDisposition(
            caller: Caller,
            attemptDidStart: Bool,
            didFinishAttempt: Bool,
            joinedTerminationFailureRetriesRemaining: Int
        ) -> FailureDisposition {
            if caller == .applicationTermination,
               !attemptDidStart,
               joinedTerminationFailureRetriesRemaining > 0 {
                return .retryTerminationStopFirst(
                    remainingRetries:
                        joinedTerminationFailureRetriesRemaining - 1
                )
            }
            if caller != .automatic, didFinishAttempt {
                return .rearmAutomaticRecovery
            }
            return .keepRetainedForExistingRecovery
        }
    }

    struct VerifiedCompletedReceipt: Sendable {
        let original: CompatibilityLaunchApplicationReceiptV1
        let completed: CompatibilityLaunchApplicationReceiptV1

        init(
            original: CompatibilityLaunchApplicationReceiptV1,
            completed: CompatibilityLaunchApplicationReceiptV1
        ) throws {
            try original.validate()
            try completed.validate()
            guard completed.schemaVersion == original.schemaVersion,
                  completed.providerID == original.providerID,
                  completed.receiptID == original.receiptID,
                  completed.requestDigest == original.requestDigest,
                  completed.transactionID == original.transactionID,
                  completed.evidence.appliedRequestDigest ==
                    original.evidence.appliedRequestDigest,
                  completed.evidence.capturedBaselineDigest ==
                    original.evidence.capturedBaselineDigest,
                  completed.evidence.appliedStateDigest ==
                    original.evidence.appliedStateDigest,
                  completed.evidence.providerReadbackDigest ==
                    original.evidence.providerReadbackDigest,
                  completed.evidence.componentMutationEvidence ==
                    original.evidence.componentMutationEvidence,
                  completed.evidence.restoredBaselineDigest ==
                    original.evidence.capturedBaselineDigest else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "verified-completion-binding-mismatch"
                )
            }
            self.original = original
            self.completed = completed
        }

        func completedReceipt(
            matching presentedReceipt: CompatibilityLaunchApplicationReceiptV1
        ) throws -> CompatibilityLaunchApplicationReceiptV1 {
            guard presentedReceipt == original else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "verified-completion-original-receipt-mismatch"
                )
            }
            return completed
        }
    }

    nonisolated static let completionRendezvousTimeoutNanoseconds: UInt64 =
        45_000_000_000

    /// Fail-closed ownership for the exceptional case where a launched
    /// transaction cannot be restored. Retaining these objects prevents the
    /// prefix lease and security scopes from being released merely because
    /// `prepareSteamSession` throws. Recovery must first reach the exact
    /// baseline through the normal completion boundary.
    @MainActor
    private final class FailedPostLaunchCleanupRetention:
        SteamCompatibilityFailedCleanupOwner,
        SteamCompatibilityBackgroundWorkOwner
    {
        enum State: Equatable {
            case retained
            case recovering(attempt: Int)
            case completed
        }

        let cleanupReceiptID: String
        let projection: SteamManagerCompatibilityLaunchProjectionV1
        let transactionID: UUID
        let prefixBinding: SteamCompatibilityPrefixBinding
        let runtimeScope: SecurityScopedCompatibilityRuntimeExecutableScopeV1
        let manifestScope: SecurityScopedCompatibilityManifestRootScopeV1
        let gameRootLease: CompatibilityGameRootLifetimeLeaseV1
        let prefixLease: SteamCompatibilityPrefixSessionLease
        let persistentPrefixSnapshot: SteamCompatibilityPersistentPrefixSnapshot
        let capturedBaselineDigest: String
        var automaticRecoveryTask: Task<Void, Never>?
        var automaticRecoveryCompletionState:
            SteamCompatibilityBackgroundWorkCompletionState?
        var cancelledBackgroundWorkCompletionStates:
            [SteamCompatibilityBackgroundWorkCompletionState] = []
        var automaticRecoveryToken: UUID?
        let completionRendezvous = CompatibilityCompletionRendezvous<
            SteamCompatibilityFailedCleanupCompletionProof
        >()
        var verifiedCompletionProof:
            SteamCompatibilityFailedCleanupCompletionProof?
        var recoveryAttempt = 0
        var state = State.retained

        init(
            projection: SteamManagerCompatibilityLaunchProjectionV1,
            transactionID: UUID,
            runtimeScope: SecurityScopedCompatibilityRuntimeExecutableScopeV1,
            manifestScope: SecurityScopedCompatibilityManifestRootScopeV1,
            gameRootLease: CompatibilityGameRootLifetimeLeaseV1,
            coordinatedLaunch: SteamCompatibilityCoordinatedLaunchResult
        ) {
            cleanupReceiptID =
                "post-launch-cleanup-" +
                transactionID.uuidString.lowercased()
            self.projection = projection
            self.transactionID = transactionID
            prefixBinding = coordinatedLaunch.prefixBinding
            self.runtimeScope = runtimeScope
            self.manifestScope = manifestScope
            self.gameRootLease = gameRootLease
            prefixLease = coordinatedLaunch.sessionPrefixLease
            persistentPrefixSnapshot =
                coordinatedLaunch.persistentPrefixSnapshot
            capturedBaselineDigest = coordinatedLaunch.capturedBaselineDigest
        }

        func completeFailedPostLaunchCleanup(
            using service: SteamPrefixService,
            reason: SteamCompatibilityFailedCleanupCompletionReason
        ) async throws -> SteamCompatibilityFailedCleanupCompletionProof {
            if let verifiedCompletionProof {
                return verifiedCompletionProof
            }
            let started = completionRendezvous.startOrJoin { [weak self] in
                guard let self else {
                    throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                        "failed-cleanup-owner-released"
                    )
                }
                return try await self.performVerifiedCleanup(
                    using: service,
                    permittingApplicationTerminationCleanup:
                        reason == .applicationTermination
                )
            }
            do {
                let proof = try await completionRendezvous.wait(
                    for: started.attempt,
                    timeoutNanoseconds:
                        SteamManagerCompatibilityLaunchRuntimeProviderV1
                            .completionRendezvousTimeoutNanoseconds
                )
                _ = completionRendezvous.finish(started.attempt)
                return proof
            } catch {
                if error is CancellationError, Task.isCancelled {
                    throw CancellationError()
                }
                if error as? CompatibilityCompletionRendezvousError == .timedOut {
                    throw CompatibilityCompletionRendezvousError.timedOut
                }
                if completionRendezvous.finish(started.attempt) {
                    state = .retained
                    if reason == .applicationTermination {
                        startAutomaticRecovery(using: service)
                    }
                }
                throw error
            }
        }

        func startAutomaticRecovery(using service: SteamPrefixService) {
            guard automaticRecoveryTask == nil,
                  state == .retained,
                  verifiedCompletionProof == nil else {
                return
            }
            let token = UUID()
            let completionState =
                SteamCompatibilityBackgroundWorkCompletionState()
            automaticRecoveryToken = token
            automaticRecoveryCompletionState = completionState
            automaticRecoveryTask = Task { @MainActor [weak self, weak service] in
                defer { completionState.markCompleted() }
                guard let self, let service else { return }
                defer { self.finishAutomaticRecovery(token: token) }
                var attempt = 1
                while !Task.isCancelled {
                    guard let delay = PostLaunchCleanupRetryPolicy
                        .delayBeforeAttemptSeconds(attempt) else {
                        return
                    }
                    if delay > 0 {
                        do {
                            try await Task.sleep(for: .seconds(delay))
                        } catch {
                            return
                        }
                    }
                    do {
                        guard try await service.completeFailedCompatibilityCleanup(
                            receiptID: self.cleanupReceiptID,
                            reason: .automaticRecovery
                        ) != nil else {
                            return
                        }
                        return
                    } catch {
                        if error is CancellationError, Task.isCancelled {
                            return
                        }
                        service.recordCompatibilitySessionRestorationFailure(
                            receiptID: self.cleanupReceiptID,
                            diagnostic:
                                "automatic post-launch cleanup attempt " +
                                "\(attempt) failed; retained ownership will retry: " +
                                forgePlayTechnicalErrorSummary(error)
                        )
                    }
                    if attempt < Int.max {
                        attempt += 1
                    }
                }
            }
        }

        private func performVerifiedCleanup(
            using service: SteamPrefixService,
            permittingApplicationTerminationCleanup: Bool = false
        ) async throws -> SteamCompatibilityFailedCleanupCompletionProof {
            if recoveryAttempt < Int.max {
                recoveryAttempt += 1
            }
            state = .recovering(attempt: recoveryAttempt)
            _ = try await service.shutdownCompatibilitySteamRuntime(
                runtimeExecutable: runtimeScope.url,
                prefixBinding: prefixBinding
            )
            let restoredDigest = try await service
                .completeCompatibilitySteamTransaction(
                    runtimeExecutable: runtimeScope.url,
                    rendererSelection: projection.rendererSelection,
                    videoMemorySizeMB: projection.videoMemorySizeMB,
                    persistentPrefixSnapshot: persistentPrefixSnapshot,
                    capturedBaselineDigest: capturedBaselineDigest,
                    sessionPrefixLease: prefixLease,
                    prefixBinding: prefixBinding,
                    permittingApplicationTerminationCleanup:
                        permittingApplicationTerminationCleanup
                )
            guard restoredDigest == capturedBaselineDigest else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "automatic-post-launch-restored-baseline-mismatch"
                )
            }
            let proof = SteamCompatibilityFailedCleanupCompletionProof(
                cleanupReceiptID: cleanupReceiptID,
                prefixBinding: prefixBinding,
                capturedBaselineDigest: capturedBaselineDigest,
                restoredBaselineDigest: restoredDigest
            )
            verifiedCompletionProof = proof
            state = .completed
            service.clearCompatibilitySessionRestorationFailure(
                receiptID: cleanupReceiptID
            )
            gameRootLease.close()
            manifestScope.close()
            runtimeScope.close()
            return proof
        }

        private func finishAutomaticRecovery(token: UUID) {
            guard automaticRecoveryToken == token else { return }
            automaticRecoveryToken = nil
            automaticRecoveryTask = nil
            automaticRecoveryCompletionState = nil
        }

        func cancelCompatibilityBackgroundWork()
            -> [SteamCompatibilityBackgroundWorkCompletionState]
        {
            var completionStates = cancelledBackgroundWorkCompletionStates
                .filter { !$0.isCompleted }
            if let automaticRecoveryTask {
                self.automaticRecoveryTask = nil
                automaticRecoveryToken = nil
                automaticRecoveryTask.cancel()
                if let automaticRecoveryCompletionState {
                    completionStates.append(
                        automaticRecoveryCompletionState
                    )
                }
                self.automaticRecoveryCompletionState = nil
            }
            if let completionState = completionRendezvous.cancelActiveAttempt() {
                completionStates.append(completionState)
            }
            var seen = Set<ObjectIdentifier>()
            cancelledBackgroundWorkCompletionStates = completionStates.filter {
                seen.insert(ObjectIdentifier($0)).inserted
            }
            return cancelledBackgroundWorkCompletionStates
        }
    }

    private static let providerID = "forgeplay.steam-manager-runtime-v1"

    private let steamPrefixService: SteamPrefixService
    private let steamManager: SteamManager
    private let windowsRuntimeService: WindowsRuntimeService
    private let context: SteamManagerCompatibilityLaunchContextV1
    private var verifiedCompletedReceipts:
        [String: VerifiedCompletedReceipt] = [:]

    init(
        steamPrefixService: SteamPrefixService,
        steamManager: SteamManager,
        windowsRuntimeService: WindowsRuntimeService,
        context: SteamManagerCompatibilityLaunchContextV1
    ) {
        self.steamPrefixService = steamPrefixService
        self.steamManager = steamManager
        self.windowsRuntimeService = windowsRuntimeService
        self.context = context
    }

    func capabilities() async throws -> CompatibilitySteamLaunchRuntimeCapabilitiesV1 {
        let runtimeScope = try SecurityScopedCompatibilityRuntimeExecutableScopeV1(
            bookmark: context.runtimeExecutableBookmark
        )
        defer { runtimeScope.close() }
        let snapshot = try await windowsRuntimeService.runtimeCapabilitySnapshot(
            executable: runtimeScope.url
        )
        return Self.capabilities(
            for: SteamCompatibilityLaunchProfileCatalogV1.recipes,
            dxvkAvailability: SteamRendererPolicyPreference.vulkan.availability(
                in: snapshot.capability
            )
        )
    }

    /// The provider-owned capability constructor used by both production
    /// admission and recipe drift tests. Keep this projection narrower than
    /// the catalog whenever the application/readback boundary is narrower.
    nonisolated static func capabilities(
        for recipes: [SteamCompatibilityLaunchProfileRecipeV1],
        dxvkAvailability: SteamRendererPolicyAvailability? = nil
    ) -> CompatibilitySteamLaunchRuntimeCapabilitiesV1 {
        var supportedGraphicsBackends = Set(
            recipes.flatMap(\.supportedOptions.graphicsBackends)
        )
        if dxvkAvailability?.isAvailable != true {
            supportedGraphicsBackends.remove(.dxvk)
        }
        return CompatibilitySteamLaunchRuntimeCapabilitiesV1(
            supportedProfileContractVersions: Set(recipes.map(\.contractVersion)),
            supportedRecipeSchemaVersions: Set(recipes.map(\.schemaVersion)),
            // The catalog keeps DXVK so persisted selections round-trip
            // without substitution. Runtime admission is fail-closed unless
            // this exact inspected generation passed the actual-device gate.
            supportedGraphicsBackends: supportedGraphicsBackends,
            supportedNetworkPolicies: Set(
                recipes.flatMap(\.supportedOptions.networkPolicies)
            ),
            supportedAudioInputPolicies: Set(
                recipes.flatMap(\.supportedOptions.audioInputPolicies)
            ),
            supportedSynchronizationPolicies: [.automatic],
            supportedVideoMemoryPolicies: Set(
                recipes.flatMap(\.supportedOptions.videoMemoryPolicies)
            ),
            supportedFrameGenerationTargetFrameRates: Set(
                recipes.flatMap(\.supportedOptions.frameGenerationTargetFrameRates)
            ),
            supportsGameModeSelection: true,
            supportsHeapZeroMemorySelection: true,
            // CoreGraphics cursor capture is session-global and cannot be
            // safely attributed to one Wine game window, so the provider
            // advertises only the non-mutating policy.
            supportedFPSCursorPolicies: [.off],
            // Automatic mode uses the bundled Wine macOS IOHID passthrough
            // without a separate bridge or registry mutation. Host inventory
            // is diagnostic only; actual Wine-child slot enumeration remains
            // an explicitly unverified real-device QA boundary. All mutating
            // controller policies still fail before SteamManager mutation.
            supportedControllerPolicies: [.automatic],
            // `systemDefault` is the sole honest no-mutation disposition.
            // Named/custom mappings remain unavailable until their effective
            // Wine-child state can be applied and independently read back.
            supportedKeyboardPresets: [.systemDefault],
            supportsCustomKeyboardPermutation: false,
            supportedProcessMatchers: Set(
                recipes.flatMap(\.automaticRequiredPolicies).map(\.matcher)
            ),
            supportedProcessPolicyActions: Set(
                recipes.flatMap(\.automaticRequiredPolicies).map(\.action)
            )
        )
    }

    func prepareSteamSession(
        request: ResolvedCompatibilityLaunchRequestV1
    ) async throws -> CompatibilityLaunchApplicationReceiptV1 {
        try SteamManagerCompatibilityControlBoundaryV1.requireConsumableRequest(
            request
        )
        // The provider owns one SteamShared prefix. A failed cleanup retains
        // that prefix lease independently of the request UUID, so a fresh
        // transaction must not bypass recovery by presenting a new ID.
        guard !steamPrefixService.hasRetainedCompatibilityCleanupOwnership else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "post-launch-cleanup-recovery-already-active"
            )
        }
        let projection = try SteamManagerCompatibilityLaunchRequestMapperV1.projection(
            for: request
        )
        // Reject unsupported input/controller requests before acquiring any
        // runtime/library scope and before the prefix service can mutate or
        // spawn. This repeats the SteamManager boundary intentionally because
        // the provider owns the compatibility transaction's earlier edge.
        try SteamInputCompatibilitySession.requireSupported(
            cursorPolicy: projection.fpsCursorPolicy,
            keyboardMapping: projection.keyboardMapping
        )
        try SteamControllerCompatibilitySession.requireSupported(
            policy: projection.controllerPolicy,
            inventory: .current()
        )
        let runtimeScope = try SecurityScopedCompatibilityRuntimeExecutableScopeV1(
            bookmark: context.runtimeExecutableBookmark
        )
        var retainedFailedPostLaunchCleanup = false
        do {
            let manifestScope = try SecurityScopedCompatibilityManifestRootScopeV1(
                authorization: request.manifestRootAuthorization
            )
            do {
                let gameRootLease = try CompatibilityGameRootLifetimeLeaseV1(
                    authorization: manifestScope.libraryAuthorization
                )
                let managedWineChildPolicy = try Self.makeManagedWineChildPolicy(
                    request: request,
                    libraryAuthorization: manifestScope.libraryAuthorization,
                    anchoredPathIdentity: gameRootLease.identitySet
                )
                try gameRootLease.revalidate()
                guard try Self.canonicalObjectIdentityDigest(
                    for: managedWineChildPolicy.canonicalGameRoot
                ) == managedWineChildPolicy.canonicalGameRootIdentityDigest else {
                    throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                        "changed-game-root-policy-identity"
                    )
                }

                let coordinatedLaunch = try await steamPrefixService
                    .launchCompatibilitySteamTransaction(
                    runtimeExecutable: runtimeScope.url,
                    request: request,
                    managedWineChildPolicy: managedWineChildPolicy,
                    steamClientLanguage: context.steamClientLanguage,
                    steamArguments: context.steamArguments,
                    // Preserve the exact selected capability. SteamManager
                    // maps a selected SteamLibrary root, while a directly
                    // selected steamapps root is only granted to this launch;
                    // it is never promoted to its unselected parent.
                    libraryRoots: [manifestScope.libraryAuthorization.selectedRoot],
                    reservedLibraryRoots: context.reservedRoots
                )
                do {
                let result = coordinatedLaunch.processResult
                guard result.succeeded else {
                    throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                        "steam-manager-launch-result"
                    )
                }
                try Self.requireLaunchEnvironmentProjection(
                    result.managedWineLaunchEnvironmentProjection,
                    expectedRosettaAVXPolicy:
                        result.managedWineRosettaAVXPolicy,
                    policy: managedWineChildPolicy,
                    expectedRequestProjection: projection
                )
                try gameRootLease.revalidate()

                let readbackProjection = try SteamManagerCompatibilityLaunchRequestMapperV1
                    .projection(for: request)
                guard readbackProjection == projection,
                      readbackProjection.authorizedManifestRootDigest ==
                        request.manifestRootAuthorization.authorizationDigest else {
                    throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                        "steam-manager-projection-evidence"
                    )
                }

                let receipt = try CompatibilityLaunchApplicationReceiptV1(
                    providerID: Self.providerID,
                    receiptID: UUID().uuidString.lowercased(),
                    requestDigest: request.canonicalDigest,
                    transactionID: request.transactionID,
                    evidence: CompatibilityRuntimeApplicationEvidenceV1(
                        appliedRequestDigest: request.canonicalDigest,
                        capturedBaselineDigest:
                            coordinatedLaunch.capturedBaselineDigest,
                        appliedStateDigest:
                            coordinatedLaunch.appliedStateDigest,
                        providerReadbackDigest:
                            coordinatedLaunch.providerReadbackDigest,
                        componentMutationEvidence:
                            coordinatedLaunch.componentMutationEvidence,
                        restoredBaselineDigest: nil
                    )
                )
                try steamPrefixService.retainCompatibilitySessionLifetime(
                    receiptID: receipt.receiptID,
                    owner: ActiveSession(
                        projection: projection,
                        receipt: receipt,
                        prefixBinding: coordinatedLaunch.prefixBinding,
                        runtimeScope: runtimeScope,
                        manifestScope: manifestScope,
                        gameRootLease: gameRootLease,
                        prefixLease: coordinatedLaunch.sessionPrefixLease,
                        persistentPrefixSnapshot:
                            coordinatedLaunch.persistentPrefixSnapshot
                    )
                )
                startAutomaticCompletion(for: receipt.receiptID)
                return receipt
                } catch let postLaunchError {
                    var cleanupProcessResults: [ProcessRunResult] = []
                    do {
                        cleanupProcessResults.append(
                            try await steamPrefixService
                                .shutdownCompatibilitySteamRuntime(
                                    runtimeExecutable: runtimeScope.url,
                                    prefixBinding:
                                        coordinatedLaunch.prefixBinding
                                )
                        )
                        let restoredDigest = try await steamPrefixService
                            .completeCompatibilitySteamTransaction(
                                runtimeExecutable: runtimeScope.url,
                                rendererSelection:
                                    projection.rendererSelection,
                                videoMemorySizeMB:
                                    projection.videoMemorySizeMB,
                                persistentPrefixSnapshot:
                                    coordinatedLaunch.persistentPrefixSnapshot,
                                capturedBaselineDigest:
                                    coordinatedLaunch.capturedBaselineDigest,
                                sessionPrefixLease:
                                    coordinatedLaunch.sessionPrefixLease,
                                prefixBinding:
                                    coordinatedLaunch.prefixBinding
                            )
                        guard restoredDigest ==
                                coordinatedLaunch.capturedBaselineDigest else {
                            throw SteamCompatibilityLaunchProfileErrorV1
                                .invalidReceipt(
                                    "post-launch-failure-restored-baseline-mismatch"
                                )
                        }
                    } catch let cleanupError {
                        let retention = FailedPostLaunchCleanupRetention(
                            projection: projection,
                            transactionID: request.transactionID,
                            runtimeScope: runtimeScope,
                            manifestScope: manifestScope,
                            gameRootLease: gameRootLease,
                            coordinatedLaunch: coordinatedLaunch
                        )
                        try steamPrefixService
                            .retainFailedCompatibilityCleanupOwner(retention)
                        retainedFailedPostLaunchCleanup = true
                        steamPrefixService
                            .recordCompatibilitySessionRestorationFailure(
                                receiptID: retention.cleanupReceiptID,
                                diagnostic:
                                    "initial post-launch cleanup failed: " +
                                    forgePlayTechnicalErrorSummary(cleanupError)
                            )
                        retention.startAutomaticRecovery(
                            using: steamPrefixService
                        )
                        throw SteamPrefixLifecycleCleanupError(
                            originalDescription:
                                forgePlayTechnicalErrorSummary(postLaunchError),
                            cleanupDescription:
                                forgePlayTechnicalErrorSummary(cleanupError),
                            originalError: postLaunchError,
                            cleanupError: cleanupError,
                            originalProcessResult:
                                coordinatedLaunch.processResult,
                            cleanupProcessResults:
                                cleanupProcessResults +
                                diagnosticProcessRunResults(from: cleanupError)
                        )
                    }
                    throw postLaunchError
                }
            } catch {
                if !retainedFailedPostLaunchCleanup {
                    manifestScope.close()
                }
                throw error
            }
        } catch {
            if !retainedFailedPostLaunchCleanup {
                runtimeScope.close()
            }
            throw error
        }
    }

    func completeSteamSession(
        receipt: CompatibilityLaunchApplicationReceiptV1
    ) async throws -> CompatibilityLaunchApplicationReceiptV1 {
        try await completeSteamSession(
            receipt: receipt,
            stoppingManagedRuntimeFirst: false,
            initiatedAutomatically: false
        )
    }

    func completeSteamSessionForApplicationTermination(
        receipt: CompatibilityLaunchApplicationReceiptV1
    ) async throws -> CompatibilityLaunchApplicationReceiptV1 {
        try await completeSteamSession(
            receipt: receipt,
            stoppingManagedRuntimeFirst: true,
            initiatedAutomatically: false
        )
    }

    private func completeSteamSession(
        receipt: CompatibilityLaunchApplicationReceiptV1,
        stoppingManagedRuntimeFirst: Bool,
        initiatedAutomatically: Bool,
        joinedTerminationFailureRetriesRemaining: Int = 1
    ) async throws -> CompatibilityLaunchApplicationReceiptV1 {
        _ = try Self.requiredCapturedBaselineDigest(in: receipt)
        if let completed = try verifiedCompletedReceipt(for: receipt) {
            return completed
        }
        guard receipt.providerID == Self.providerID,
              let session = steamPrefixService
                .compatibilitySessionLifetimeOwner(
                    receiptID: receipt.receiptID
                ) as? ActiveSession,
              session.receipt == receipt else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "unknown-or-mismatched-active-session"
            )
        }
        if stoppingManagedRuntimeFirst {
            // Escalation is sticky for the retained owner. If termination joins
            // an automatic attempt before its body starts, that same operation
            // will stop the runtime first. If it was already past this boundary
            // and fails, the bounded joined-failure retry below starts a new
            // stop-first attempt without overlapping the original task.
            session.completionOwnershipPolicy
                .registerApplicationTerminationRequest()
        }
        let started = session.completionRendezvous.startOrJoin {
            [weak self, weak session] in
            guard let self, let session else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "compatibility-session-owner-released"
                )
            }
            return try await self.performVerifiedSteamSessionCompletion(
                receipt: receipt,
                session: session,
                stoppingManagedRuntimeFirst:
                    session.completionOwnershipPolicy.requiresRuntimeStopFirst(
                        requestedByAttemptOwner: stoppingManagedRuntimeFirst
                    )
            )
        }
        do {
            let completed = try await session.completionRendezvous.wait(
                for: started.attempt,
                timeoutNanoseconds: Self.completionRendezvousTimeoutNanoseconds
            )
            _ = session.completionRendezvous.finish(started.attempt)
            return completed
        } catch {
            if error is CancellationError, Task.isCancelled {
                throw CancellationError()
            }
            if error as? CompatibilityCompletionRendezvousError == .timedOut {
                throw CompatibilityCompletionRendezvousError.timedOut
            }
            let didFinishAttempt = session.completionRendezvous.finish(
                started.attempt
            )
            let caller: CompletionOwnershipPolicyV1.Caller
            if initiatedAutomatically {
                caller = .automatic
            } else if stoppingManagedRuntimeFirst {
                caller = .applicationTermination
            } else {
                caller = .manual
            }
            switch session.completionOwnershipPolicy.failureDisposition(
                caller: caller,
                attemptDidStart: started.didStart,
                didFinishAttempt: didFinishAttempt,
                joinedTerminationFailureRetriesRemaining:
                    joinedTerminationFailureRetriesRemaining
            ) {
            case .retryTerminationStopFirst(let remainingRetries):
                return try await completeSteamSession(
                    receipt: receipt,
                    stoppingManagedRuntimeFirst: true,
                    initiatedAutomatically: false,
                    joinedTerminationFailureRetriesRemaining:
                        remainingRetries
                )
            case .rearmAutomaticRecovery:
                startAutomaticCompletion(for: receipt.receiptID)
            case .keepRetainedForExistingRecovery:
                break
            }
            throw error
        }
    }

    private func performVerifiedSteamSessionCompletion(
        receipt: CompatibilityLaunchApplicationReceiptV1,
        session: ActiveSession,
        stoppingManagedRuntimeFirst: Bool
    ) async throws -> CompatibilityLaunchApplicationReceiptV1 {
        let capturedBaselineDigest = try Self.requiredCapturedBaselineDigest(
            in: receipt
        )
        // Build and fully bind the handoff before the prefix lease can be
        // released. Once restoration succeeds, no fallible receipt construction
        // is allowed to strand an exactly restored session with an unusable
        // released lease.
        let completed = try Self.completedReceipt(
            from: receipt,
            restoredBaselineDigest: capturedBaselineDigest
        )
        let verifiedCompletion = try VerifiedCompletedReceipt(
            original: receipt,
            completed: completed
        )
        _ = session.restorationMachine.beginAttempt()
        session.restorationMachine.beginRestoration()
        if stoppingManagedRuntimeFirst {
            _ = try await steamPrefixService.shutdownCompatibilitySteamRuntime(
                runtimeExecutable: session.runtimeScope.url,
                prefixBinding: session.prefixBinding
            )
        }
        let gameRootIntegrityDiagnostic: String?
        do {
            try session.gameRootLease.revalidate()
            gameRootIntegrityDiagnostic = nil
        } catch {
            // Library identity is launch evidence, not a prerequisite for
            // restoring the already-mutated singleton prefix. Preserve the
            // integrity failure for the caller, but never let an unmounted or
            // replaced game root strand cleanup ownership.
            gameRootIntegrityDiagnostic = forgePlayTechnicalErrorSummary(error)
        }
        let restoredDigest = try await steamPrefixService
            .completeCompatibilitySteamTransaction(
                runtimeExecutable: session.runtimeScope.url,
                rendererSelection: session.projection.rendererSelection,
                videoMemorySizeMB: session.projection.videoMemorySizeMB,
                persistentPrefixSnapshot: session.persistentPrefixSnapshot,
                capturedBaselineDigest: capturedBaselineDigest,
                sessionPrefixLease: session.prefixLease,
                prefixBinding: session.prefixBinding,
                permittingApplicationTerminationCleanup:
                    stoppingManagedRuntimeFirst
            )
        guard restoredDigest == capturedBaselineDigest else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "restored-baseline-mismatch"
            )
        }
        session.restorationMachine.recordVerifiedRestoration()
        guard session.restorationMachine.permitsRelease else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "restoration-release-gate"
            )
        }
        // Keep an in-memory verified handoff until the navigation-stable owner
        // accepts the completed receipt. This also makes an automatic or
        // post-restoration diagnostic completion safely retryable without
        // re-acquiring resources that were already released.
        verifiedCompletedReceipts[receipt.receiptID] = verifiedCompletion
        if let gameRootIntegrityDiagnostic {
            steamPrefixService.recordCompatibilitySessionRestorationFailure(
                receiptID: receipt.receiptID,
                diagnostic:
                    "prefix baseline restored; game-root integrity " +
                    "revalidation failed: \(gameRootIntegrityDiagnostic)"
            )
        } else {
            steamPrefixService.clearCompatibilitySessionRestorationFailure(
                receiptID: receipt.receiptID
            )
        }
        steamPrefixService.releaseCompatibilitySessionLifetime(
            receiptID: receipt.receiptID
        )
        session.gameRootLease.close()
        session.manifestScope.close()
        session.runtimeScope.close()
        if let gameRootIntegrityDiagnostic {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "game-root-integrity-after-restoration: " +
                gameRootIntegrityDiagnostic
            )
        }
        return completed
    }

    private func startAutomaticCompletion(for receiptID: String) {
        guard let session = steamPrefixService.compatibilitySessionLifetimeOwner(
            receiptID: receiptID
        ) as? ActiveSession else { return }
        if let existingTask = session.automaticCompletionTask {
            existingTask.cancel()
            if let existingState = session.automaticCompletionState,
               !existingState.isCompleted {
                session.supersededAutomaticCompletionStates.append(
                    existingState
                )
            }
        }
        let completionState =
            SteamCompatibilityBackgroundWorkCompletionState()
        session.automaticCompletionState = completionState
        let service = steamPrefixService
        session.automaticCompletionTask = Task { @MainActor [weak self, weak service] in
            defer { completionState.markCompleted() }
            while !Task.isCancelled {
                guard let self, let service else { return }
                guard let retained = service.compatibilitySessionLifetimeOwner(
                    receiptID: receiptID
                ) as? ActiveSession else { return }
                do {
                    let inactive = try await service
                        .waitForCompatibilitySteamTransactionToBecomeInactive(
                            prefixBinding: retained.prefixBinding
                        )
                    guard !Task.isCancelled else { return }
                    guard inactive else {
                        throw SteamCompatibilityLaunchProfileErrorV1
                            .invalidReceipt(
                                "automatic-inactivity-observation-timeout"
                            )
                    }
                    _ = try await self.completeSteamSession(
                        receipt: retained.receipt,
                        stoppingManagedRuntimeFirst: false,
                        initiatedAutomatically: true
                    )
                    return
                } catch {
                    if error is CancellationError, Task.isCancelled {
                        return
                    }
                    let diagnostic = forgePlayTechnicalErrorSummary(error)
                    service.recordCompatibilitySessionRestorationFailure(
                        receiptID: receiptID,
                        diagnostic: diagnostic
                    )
                    let delay = retained.restorationMachine.recordFailure(
                        diagnostic
                    )
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                }
            }
        }
    }

    func restorationFailureState(receiptID: String) -> String? {
        steamPrefixService.compatibilitySessionRestorationFailure(
            receiptID: receiptID
        )
    }

    private static func requiredCapturedBaselineDigest(
        in receipt: CompatibilityLaunchApplicationReceiptV1
    ) throws -> String {
        guard let capturedBaselineDigest = receipt.evidence.capturedBaselineDigest else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "missing-captured-baseline-digest"
            )
        }
        try receipt.validate()
        return capturedBaselineDigest
    }

    private func verifiedCompletedReceipt(
        for receipt: CompatibilityLaunchApplicationReceiptV1
    ) throws -> CompatibilityLaunchApplicationReceiptV1? {
        guard let verified = verifiedCompletedReceipts[receipt.receiptID] else {
            return nil
        }
        return try verified.completedReceipt(matching: receipt)
    }

    private static func completedReceipt(
        from receipt: CompatibilityLaunchApplicationReceiptV1,
        restoredBaselineDigest: String
    ) throws -> CompatibilityLaunchApplicationReceiptV1 {
        try CompatibilityLaunchApplicationReceiptV1(
            providerID: receipt.providerID,
            receiptID: receipt.receiptID,
            requestDigest: receipt.requestDigest,
            transactionID: receipt.transactionID,
            evidence: CompatibilityRuntimeApplicationEvidenceV1(
                appliedRequestDigest: receipt.evidence.appliedRequestDigest,
                capturedBaselineDigest: receipt.evidence.capturedBaselineDigest,
                appliedStateDigest: receipt.evidence.appliedStateDigest,
                providerReadbackDigest: receipt.evidence.providerReadbackDigest,
                componentMutationEvidence:
                    receipt.evidence.componentMutationEvidence,
                restoredBaselineDigest: restoredBaselineDigest
            )
        )
    }

    private static func makeManagedWineChildPolicy(
        request: ResolvedCompatibilityLaunchRequestV1,
        libraryAuthorization: CompatibilitySteamLibraryRootAuthorizationV1,
        anchoredPathIdentity: CompatibilityAnchoredPathIdentityV1
    ) throws -> SteamManagedWineChildCompatibilityPolicy {
        guard request.identity.steamAppID ==
                SteamManagedWineChildCompatibilityPolicy
                    .helldivers2SteamAppID,
              request.snapshot.automaticRequiredPolicies.count == 1 else {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "managed-wine-child-policy",
                value: "unsupported-profile-or-ambiguous-policy"
            )
        }

        let canonicalGameRoot = libraryAuthorization.gameRoot
        let identityDigest = try Self.canonicalObjectIdentityDigest(
            for: canonicalGameRoot
        )
        return try SteamManagedWineChildCompatibilityPolicy(
            steamAppID: request.identity.steamAppID,
            canonicalGameRoot: canonicalGameRoot,
            canonicalGameRootIdentityDigest: identityDigest,
            anchoredLibraryPathIdentity: anchoredPathIdentity,
            manifestRootAuthorizationDigest:
                request.manifestRootAuthorization.authorizationDigest,
            lineageNonce: UUID(),
            heapZeroMemoryEnabled:
                request.snapshot.heapZeroMemoryEnabled.value,
            excludesGameGuardRenderer: true
        )
    }

    nonisolated static func requireLaunchEnvironmentProjection(
        _ projection: ManagedWineLaunchEnvironmentProjection?,
        expectedRosettaAVXPolicy: ManagedWineRosettaAVXPolicyV1?,
        policy: SteamManagedWineChildCompatibilityPolicy,
        expectedRequestProjection:
            SteamManagerCompatibilityLaunchProjectionV1
    ) throws {
        _ = expectedRosettaAVXPolicy
        let transportIsAdmitted =
            expectedRequestProjection.gameModePolicy == .standard ||
            projection?.transport == "game-mode-host"
        let expectedRoot = "Z:" + policy.canonicalGameRoot.path
            .replacingOccurrences(of: "/", with: "\\")
        guard let projection,
              transportIsAdmitted,
              projection.policyVersion ==
                Helldivers2ManagedWineChildPolicyContract.policyVersion,
              projection.hostAuthorization ==
                Helldivers2ManagedWineChildPolicyContract.hostAuthorization,
              projection.steamAppID == policy.steamAppID,
              projection.canonicalGameRoot == expectedRoot,
              projection.canonicalGameRootIdentityTelemetryDigest ==
                policy.canonicalGameRootIdentityDigest,
              projection.manifestRootAuthorizationTelemetryDigest ==
                policy.manifestRootAuthorizationDigest,
              projection.lineageNonce ==
                policy.lineageNonce.uuidString.lowercased(),
              projection.gameGuardRendererExclusionRequested == "1",
              gameModeProjectionMatches(
                projection,
                expectedPolicy: expectedRequestProjection.gameModePolicy
              ) else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "managed-wine-launch-environment-projection"
            )
        }
    }

    private nonisolated static func gameModeProjectionMatches(
        _ projection: ManagedWineLaunchEnvironmentProjection,
        expectedPolicy: SteamGameModeLaunchPolicy
    ) -> Bool {
        switch expectedPolicy {
        case .standard:
            return true
        case .experimentalRequiredHost:
            return projection.transport == "game-mode-host" &&
                projection.gameModeHostRequested == "1" &&
                projection.gameModeHostAvailability == "ready" &&
                projection.gameModeHostDisabledReason == nil
        }
    }

    private nonisolated static func frameGenerationProjectionMatches(
        _ projection: ManagedWineLaunchEnvironmentProjection,
        expectedConfiguration: FrameGenerationConfiguration
    ) -> Bool {
        guard expectedConfiguration.isEnabled else {
            return projection.frameGenerationEnabled == nil &&
                projection.frameGenerationTargetFrameRate == nil &&
                projection.frameCheckEnabled == nil &&
                projection.frameGenerationProxyPath == nil
        }
        return projection.frameGenerationEnabled == "1" &&
            projection.frameGenerationTargetFrameRate ==
                String(expectedConfiguration.targetFrameRate.rawValue) &&
            projection.frameCheckEnabled ==
                (expectedConfiguration.isFrameCheckEnabled ? "1" : "0") &&
            projection.frameGenerationProxyPath?.hasPrefix("/") == true
    }

    nonisolated static func requireManagedWineChildSynchronizationReadback(
        _ readback: ManagedWineChildSynchronizationReadback?,
        processIdentifier: Int32,
        expectedSelection: WineSynchronizationSelection
    ) throws {
        guard let readback,
              readback.processIdentifier == processIdentifier,
              readback.selection == expectedSelection,
              readback.backend == .server else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "managed-wine-child-synchronization-readback"
            )
        }
    }

    private static func canonicalObjectIdentityDigest(
        for url: URL
    ) throws -> String {
        let values = try url.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .volumeIdentifierKey,
                .fileResourceIdentifierKey
            ]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              let volume = values.volumeIdentifier,
              let file = values.fileResourceIdentifier else {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "managed-wine-child-policy",
                value: "missing-canonical-object-identity"
            )
        }
        let volumeData = try NSKeyedArchiver.archivedData(
            withRootObject: volume,
            requiringSecureCoding: true
        )
        let fileData = try NSKeyedArchiver.archivedData(
            withRootObject: file,
            requiringSecureCoding: true
        )
        var data = Data("forgeplay-helldivers2-root-identity-v1\n".utf8)
        data.append(volumeData)
        data.append(fileData)
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

}

private final class SecurityScopedCompatibilityRuntimeExecutableScopeV1 {
    let url: URL
    private(set) var isOpen = false

    init(bookmark: Data) throws {
        var isStale = false
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "runtime-executable-authorization",
                value: "bookmark-resolution"
            )
        }
        guard !isStale else {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "runtime-executable-authorization",
                value: "stale-bookmark"
            )
        }
        guard url.startAccessingSecurityScopedResource() else {
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "runtime-executable-authorization",
                value: "security-scope-denied"
            )
        }
        isOpen = true
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [.isRegularFileKey]
            )
        } catch {
            close()
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "runtime-executable",
                value: "metadata-readback"
            )
        }
        guard values.isRegularFile == true,
              FileManager.default.isExecutableFile(atPath: url.path) else {
            close()
            throw SteamCompatibilityLaunchProfileErrorV1.unsupportedCapability(
                category: "runtime-executable",
                value: "not-executable-regular-file"
            )
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        url.stopAccessingSecurityScopedResource()
    }

    deinit { close() }
}

/// Holds the authorized game directory object open for the entire provider
/// session and rejects path replacement before launch completion.
private final class CompatibilityGameRootLifetimeLeaseV1 {
    private struct HeldEntry {
        let identity: CompatibilityAnchoredPathIdentityV1.Entry
        var descriptor: Int32
    }

    let identitySet: CompatibilityAnchoredPathIdentityV1
    private var heldEntries: [HeldEntry]

    init(
        authorization: CompatibilitySteamLibraryRootAuthorizationV1
    ) throws {
        let directoryURLs = [
            authorization.selectedRoot,
            authorization.steamAppsRoot,
            authorization.commonRoot,
            authorization.gameRoot
        ]
        let regularFileURLs = [authorization.manifestURL]
        var seen = Set<String>()
        var opened: [HeldEntry] = []
        do {
            for (url, kind) in
                directoryURLs.map({ ($0, CompatibilityAnchoredPathIdentityV1.Kind.directory) }) +
                regularFileURLs.map({ ($0, CompatibilityAnchoredPathIdentityV1.Kind.regularFile) }) {
                let normalized = url.standardizedFileURL
                guard seen.insert(normalized.path).inserted else { continue }
                let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW |
                    (kind == .directory ? O_DIRECTORY : 0)
                let descriptor = Darwin.open(normalized.path, flags)
                guard descriptor >= 0 else {
                    throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                        "library-lifetime-open"
                    )
                }
                var status = stat()
                let expectedType: mode_t = kind == .directory
                    ? mode_t(S_IFDIR)
                    : mode_t(S_IFREG)
                guard fstat(descriptor, &status) == 0,
                      (status.st_mode & S_IFMT) == expectedType,
                      kind == .directory || status.st_nlink == 1 else {
                    Darwin.close(descriptor)
                    throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                        "library-lifetime-identity"
                    )
                }
                opened.append(
                    HeldEntry(
                        identity: CompatibilityAnchoredPathIdentityV1.Entry(
                            path: normalized.path,
                            kind: kind,
                            device: UInt64(status.st_dev),
                            inode: UInt64(status.st_ino)
                        ),
                        descriptor: descriptor
                    )
                )
            }
            guard opened.count >= 4 else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "library-lifetime-closure"
                )
            }
            let capabilityLease = try CompatibilityAnchoredPathCapabilityLeaseV1(
                entries: opened.map(\.identity),
                descriptors: opened.map(\.descriptor)
            )
            heldEntries = opened
            identitySet = CompatibilityAnchoredPathIdentityV1(
                entries: opened.map(\.identity),
                capabilityLease: capabilityLease
            )
        } catch {
            opened.forEach { Darwin.close($0.descriptor) }
            throw error
        }
    }

    func revalidate() throws {
        guard !heldEntries.isEmpty else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "closed-game-root-lifetime"
            )
        }
        for entry in heldEntries {
            var held = stat()
            guard fstat(entry.descriptor, &held) == 0,
                  UInt64(held.st_dev) == entry.identity.device,
                  UInt64(held.st_ino) == entry.identity.inode else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "replaced-held-library-object"
                )
            }
        }
        try identitySet.revalidate()
    }

    func close() {
        heldEntries.forEach { Darwin.close($0.descriptor) }
        heldEntries.removeAll()
    }

    deinit { close() }
}

private struct CompatibilitySteamLibraryRootAuthorizationV1 {
    enum RootKind: String, Hashable, Sendable {
        case steamLibraryRoot
        case steamAppsRoot
    }

    let kind: RootKind
    let selectedRoot: URL
    let steamAppsRoot: URL
    let gameRoot: URL
    let manifestURL: URL
    let commonRoot: URL

    private struct ValidatedCandidate {
        let gameRoot: URL
        let manifestURL: URL
        let commonRoot: URL
    }

    static func resolve(
        selectedRoot: URL,
        fileManager: FileManager = .default
    ) throws -> Self {
        let selected = selectedRoot.standardizedFileURL
            .resolvingSymlinksInPath()
        guard FileSystemItemPolicy.isNonSymlinkDirectory(
            selected,
            fileManager: fileManager
        ) else {
            throw CompatibilityManifestRootAuthorizationErrorV1
                .selectedObjectIsNotDirectory
        }
        let directSteamApps = validatedCandidate(
            steamAppsRoot: selected,
            selectedRoot: selected,
            fileManager: fileManager
        )
        let nestedSteamAppsURL = selected.appending(
            path: "steamapps",
            directoryHint: .isDirectory
        )
        let nestedSteamApps = validatedCandidate(
            steamAppsRoot: nestedSteamAppsURL,
            selectedRoot: selected,
            fileManager: fileManager
        )
        switch (directSteamApps, nestedSteamApps) {
        case (.some(let candidate), .none):
            return Self(
                kind: .steamAppsRoot,
                selectedRoot: selected,
                steamAppsRoot: selected,
                gameRoot: candidate.gameRoot,
                manifestURL: candidate.manifestURL,
                commonRoot: candidate.commonRoot
            )
        case (.none, .some(let candidate)):
            return Self(
                kind: .steamLibraryRoot,
                selectedRoot: selected,
                steamAppsRoot: nestedSteamAppsURL,
                gameRoot: candidate.gameRoot,
                manifestURL: candidate.manifestURL,
                commonRoot: candidate.commonRoot
            )
        default:
            throw SteamCompatibilityLaunchProfileErrorV1
                .invalidManifestRootAuthorization(
                    "ambiguous-or-malformed-steam-library-root"
                )
        }
    }

    private static func validatedCandidate(
        steamAppsRoot: URL,
        selectedRoot: URL,
        fileManager: FileManager
    ) -> ValidatedCandidate? {
        let manifest = steamAppsRoot.appending(
            path: "appmanifest_\(SteamManagedWineChildCompatibilityPolicy.helldivers2SteamAppID).acf"
        )
        let common = steamAppsRoot.appending(
            path: "common",
            directoryHint: .isDirectory
        )
        guard let installDirectory = try? installDirectoryName(
            from: manifest
        ) else {
            return nil
        }
        let game = common.appending(
            path: installDirectory,
            directoryHint: .isDirectory
        )
        guard FileSystemItemPolicy.isNonSymlinkDirectory(
            steamAppsRoot,
            fileManager: fileManager
        ), FileSystemItemPolicy.isRegularNonSymlinkFile(
            manifest,
            fileManager: fileManager
        ), FileSystemItemPolicy.isNonSymlinkDirectory(
            common,
            fileManager: fileManager
        ), FileSystemItemPolicy.isNonSymlinkDirectory(
            game,
            fileManager: fileManager
        ), FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
            from: selectedRoot,
            to: game,
            fileManager: fileManager
        ) else {
            return nil
        }
        let canonical = game.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = selectedRoot.pathComponents
        let gameComponents = canonical.pathComponents
        guard gameComponents.count > rootComponents.count,
              Array(gameComponents.prefix(rootComponents.count)) ==
                rootComponents else {
            return nil
        }
        return ValidatedCandidate(
            gameRoot: canonical,
            manifestURL: manifest.standardizedFileURL,
            commonRoot: common.standardizedFileURL
        )
    }

    private static func installDirectoryName(from manifest: URL) throws -> String {
        let data = try readStableManifest(at: manifest)
        guard !data.contains(0) else {
            throw SteamCompatibilityLaunchProfileErrorV1
                .invalidManifestRootAuthorization("manifest-encoding")
        }
        let tokens = try tokenizeValveKeyValues(data)
        var tokenIndex = 0
        guard tokenIndex < tokens.count,
              case .string("AppState") = tokens[tokenIndex] else {
            throw SteamCompatibilityLaunchProfileErrorV1
                .invalidManifestRootAuthorization("manifest-root")
        }
        tokenIndex += 1
        let rootMembers = try parseValveKeyValuesObject(
            tokens,
            index: &tokenIndex
        )
        guard tokenIndex == tokens.count else {
            throw SteamCompatibilityLaunchProfileErrorV1
                .invalidManifestRootAuthorization("manifest-trailing-data")
        }
        let appIDs = rootMembers.compactMap { key, value -> String? in
            guard key == "appid", case .string(let value) = value else {
                return nil
            }
            return value
        }
        let installDirectories = rootMembers.compactMap {
            key, value -> String? in
            guard key == "installdir", case .string(let value) = value else {
                return nil
            }
            return value
        }
        guard appIDs == [
            SteamManagedWineChildCompatibilityPolicy.helldivers2SteamAppID
        ], installDirectories.count == 1,
        let installDirectory = installDirectories.first,
        !installDirectory.isEmpty,
        installDirectory.utf8.count <= 255,
        installDirectory != ".",
        installDirectory != "..",
        !installDirectory.contains("/"),
        !installDirectory.contains("\\"),
        !installDirectory.utf8.contains(0) else {
            throw SteamCompatibilityLaunchProfileErrorV1
                .invalidManifestRootAuthorization("manifest-identity")
        }
        return installDirectory
    }

    private enum ValveKeyValuesToken: Equatable {
        case string(String)
        case openBrace
        case closeBrace
    }

    private indirect enum ValveKeyValuesValue {
        case string(String)
        case object([(String, ValveKeyValuesValue)])
    }

    private static func tokenizeValveKeyValues(
        _ data: Data
    ) throws -> [ValveKeyValuesToken] {
        let bytes = [UInt8](data)
        var index = 0
        var tokens: [ValveKeyValuesToken] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 32 || byte == 9 || byte == 10 || byte == 13 {
                index += 1
                continue
            }
            if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 47 {
                index += 2
                while index < bytes.count,
                      bytes[index] != 10,
                      bytes[index] != 13 {
                    index += 1
                }
                continue
            }
            if byte == 123 {
                tokens.append(.openBrace)
                index += 1
            } else if byte == 125 {
                tokens.append(.closeBrace)
                index += 1
            } else if byte == 34 {
                index += 1
                var value: [UInt8] = []
                var terminated = false
                while index < bytes.count {
                    let current = bytes[index]
                    index += 1
                    if current == 34 {
                        terminated = true
                        break
                    }
                    if current == 92 {
                        guard index < bytes.count else { break }
                        let escaped = bytes[index]
                        index += 1
                        guard escaped == 34 || escaped == 92 else {
                            throw SteamCompatibilityLaunchProfileErrorV1
                                .invalidManifestRootAuthorization(
                                    "manifest-escape"
                                )
                        }
                        value.append(escaped)
                    } else {
                        guard current >= 32 else {
                            throw SteamCompatibilityLaunchProfileErrorV1
                                .invalidManifestRootAuthorization(
                                    "manifest-control-character"
                                )
                        }
                        value.append(current)
                    }
                    guard value.count <= 4_096 else {
                        throw SteamCompatibilityLaunchProfileErrorV1
                            .invalidManifestRootAuthorization(
                                "manifest-token-bounds"
                            )
                    }
                }
                guard terminated,
                      let decoded = String(bytes: value, encoding: .utf8) else {
                    throw SteamCompatibilityLaunchProfileErrorV1
                        .invalidManifestRootAuthorization("manifest-string")
                }
                tokens.append(.string(decoded))
            } else {
                throw SteamCompatibilityLaunchProfileErrorV1
                    .invalidManifestRootAuthorization("manifest-token")
            }
            guard tokens.count <= 65_536 else {
                throw SteamCompatibilityLaunchProfileErrorV1
                    .invalidManifestRootAuthorization("manifest-token-count")
            }
        }
        return tokens
    }

    private static func parseValveKeyValuesObject(
        _ tokens: [ValveKeyValuesToken],
        index: inout Int,
        depth: Int = 0
    ) throws -> [(String, ValveKeyValuesValue)] {
        guard depth <= 32,
              index < tokens.count,
              tokens[index] == .openBrace else {
            throw SteamCompatibilityLaunchProfileErrorV1
                .invalidManifestRootAuthorization("manifest-object")
        }
        index += 1
        var members: [(String, ValveKeyValuesValue)] = []
        while index < tokens.count {
            if tokens[index] == .closeBrace {
                index += 1
                return members
            }
            guard case .string(let key) = tokens[index] else {
                throw SteamCompatibilityLaunchProfileErrorV1
                    .invalidManifestRootAuthorization("manifest-key")
            }
            index += 1
            guard index < tokens.count else {
                throw SteamCompatibilityLaunchProfileErrorV1
                    .invalidManifestRootAuthorization("manifest-value")
            }
            let value: ValveKeyValuesValue
            switch tokens[index] {
            case .string(let string):
                value = .string(string)
                index += 1
            case .openBrace:
                value = .object(
                    try parseValveKeyValuesObject(
                        tokens,
                        index: &index,
                        depth: depth + 1
                    )
                )
            case .closeBrace:
                throw SteamCompatibilityLaunchProfileErrorV1
                    .invalidManifestRootAuthorization("manifest-value")
            }
            members.append((key, value))
        }
        throw SteamCompatibilityLaunchProfileErrorV1
            .invalidManifestRootAuthorization("manifest-unclosed-object")
    }

    private static func readStableManifest(at url: URL) throws -> Data {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SteamCompatibilityLaunchProfileErrorV1
                .invalidManifestRootAuthorization("manifest-open")
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= 1_048_576 else {
            throw SteamCompatibilityLaunchProfileErrorV1
                .invalidManifestRootAuthorization("manifest-bounds")
        }
        let expectedByteCount = Int(before.st_size)
        var bytes = [UInt8](repeating: 0, count: expectedByteCount)
        var offset = 0
        while offset < expectedByteCount {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    expectedByteCount - offset,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw SteamCompatibilityLaunchProfileErrorV1
                    .invalidManifestRootAuthorization("manifest-read")
            }
            offset += count
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw SteamCompatibilityLaunchProfileErrorV1
                .invalidManifestRootAuthorization("manifest-raced")
        }
        return Data(bytes)
    }
}

private final class SecurityScopedCompatibilityManifestRootScopeV1 {
    let url: URL
    private(set) var libraryAuthorization:
        CompatibilitySteamLibraryRootAuthorizationV1!
    private(set) var isOpen = false

    init(authorization: CompatibilityManifestRootAuthorizationTokenV1) throws {
        try authorization.validate()
        var isStale = false
        do {
            url = try URL(
                resolvingBookmarkData: authorization.securityScopedBookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw CompatibilityManifestRootAuthorizationErrorV1.invalidBookmark(
                "launch-resolution"
            )
        }
        guard !isStale else {
            throw CompatibilityManifestRootAuthorizationErrorV1.staleBookmark
        }
        guard url.startAccessingSecurityScopedResource() else {
            throw CompatibilityManifestRootAuthorizationErrorV1.securityScopeDenied
        }
        isOpen = true
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .volumeIdentifierKey,
                    .fileResourceIdentifierKey
                ]
            )
        } catch {
            close()
            throw CompatibilityManifestRootAuthorizationErrorV1.invalidBookmark(
                "launch-metadata-readback"
            )
        }
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            close()
            throw CompatibilityManifestRootAuthorizationErrorV1.selectedObjectIsNotDirectory
        }
        let volume: Data
        let file: Data
        do {
            volume = try Self.archivedIdentifier(values.volumeIdentifier, field: "volume")
            file = try Self.archivedIdentifier(values.fileResourceIdentifier, field: "file")
        } catch {
            close()
            throw error
        }
        guard volume == authorization.pinnedVolumeIdentifier,
              file == authorization.pinnedFileIdentifier else {
            close()
            throw CompatibilityManifestRootAuthorizationErrorV1.providerOutputMismatch
        }
        do {
            libraryAuthorization = try CompatibilitySteamLibraryRootAuthorizationV1
                .resolve(selectedRoot: url)
        } catch {
            close()
            throw error
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        url.stopAccessingSecurityScopedResource()
    }

    deinit { close() }

    private static func archivedIdentifier(
        _ value: Any?,
        field: String
    ) throws -> Data {
        guard let value = value as? any NSSecureCoding else {
            throw CompatibilityManifestRootAuthorizationErrorV1
                .missingPinnedObjectIdentity(field)
        }
        do {
            return try NSKeyedArchiver.archivedData(
                withRootObject: value,
                requiringSecureCoding: true
            )
        } catch {
            throw CompatibilityManifestRootAuthorizationErrorV1
                .missingPinnedObjectIdentity(field)
        }
    }
}
