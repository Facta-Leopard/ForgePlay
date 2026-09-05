import Foundation
import XCTest
@testable import ForgePlay

final class SteamCompatibilityLaunchProfileV1Tests: XCTestCase {
    private let recipe = SteamCompatibilityLaunchProfileCatalogV1.helldivers2

    func testAcceptedSessionPostDispatchAdvisoryReadbackFailureUsesFallback() {
        let fallback = String(repeating: "a", count: 64)
        var readAttempts = 0

        let result = SteamCompatibilityPostDispatchAdvisoryReadback.capture(
            componentID: "persistent-prefix verification snapshot",
            fallback: fallback
        ) {
            readAttempts += 1
            throw PostDispatchAdvisoryReadbackProbeError.unavailable
        }

        XCTAssertEqual(readAttempts, 1)
        XCTAssertEqual(result.value, fallback)
        XCTAssertTrue(
            result.diagnosticWarning?.contains(
                "the accepted Steam session remains active"
            ) == true
        )
        XCTAssertTrue(
            result.diagnosticWarning?.contains(
                "deterministic fallback evidence was recorded"
            ) == true
        )
    }

    func testAcceptedSessionPostDispatchAdvisoryReadbackSuccessKeepsCapturedValue() {
        let result = SteamCompatibilityPostDispatchAdvisoryReadback.capture(
            componentID: "applied-state digest",
            fallback: "fallback"
        ) {
            "captured"
        }

        XCTAssertEqual(result.value, "captured")
        XCTAssertNil(result.diagnosticWarning)
    }

    func testBuiltInRecipeIdentityDefaultsAndOrderedDescriptors() throws {
        XCTAssertEqual(recipe.identity.steamAppID, "553850")
        XCTAssertEqual(recipe.recommendations.graphicsBackend, .d3dMetalNVIDIA)
        XCTAssertTrue(recipe.recommendations.gameModeEnabled)
        XCTAssertTrue(recipe.recommendations.selections.heapZeroMemoryEnabled)
        XCTAssertEqual(
            recipe.orderedOptionDescriptors.map(\.kind),
            [
                .graphicsBackend,
                .frameGeneration,
                .gameMode,
                .heapZeroMemory,
                .automaticProcessPolicies,
                .networkPolicy,
                .audioInputPolicy,
                .synchronizationPolicy,
                .videoMemoryPolicy,
                .fpsCursorPolicy,
                .controllerPolicy,
                .keyboardMapping
            ]
        )
        XCTAssertEqual(
            Set(recipe.orderedOptionDescriptors.map(\.kind)),
            Set(CompatibilitySteamLaunchOptionKindV1.allCases)
        )
        XCTAssertEqual(recipe.supportedOptions.fpsCursorPolicies, [.off])
        XCTAssertEqual(
            recipe.supportedOptions.controllerPolicies,
            [.automatic]
        )
        XCTAssertEqual(recipe.initialSelections.keyboardMapping, .systemDefault)
        XCTAssertEqual(recipe.recommendations.selections.keyboardMapping, .systemDefault)
        XCTAssertEqual(recipe.supportedOptions.keyboardPresets, [.systemDefault])
        XCTAssertFalse(recipe.supportedOptions.supportsCustomKeyboardPermutation)
        XCTAssertEqual(recipe.automaticRequiredPolicies.count, 1)
        XCTAssertEqual(
            recipe.automaticRequiredPolicies.first?.matcher,
            .gameGuardFamilyASCIIComponentOrFinalStem
        )
    }

    func testPersistenceBlockedLegacyDraftStillAllowsRecommendationRecovery() {
        XCTAssertFalse(
            CompatibilityProfileDraftInteractionPolicy
                .recommendationsRestoreIsDisabled(
                    isPersistenceBlocked: true,
                    isPreparingSession: false,
                    hasActiveSession: false,
                    isSteamLaunchInProgress: false,
                    isStandardSteamLaunchReserved: false
                )
        )

        let unsafeTransitionStates: [(Bool, Bool, Bool, Bool)] = [
            (true, false, false, false),
            (false, true, false, false),
            (false, false, true, false),
            (false, false, false, true)
        ]
        for state in unsafeTransitionStates {
            XCTAssertTrue(
                CompatibilityProfileDraftInteractionPolicy
                    .recommendationsRestoreIsDisabled(
                        isPersistenceBlocked: true,
                        isPreparingSession: state.0,
                        hasActiveSession: state.1,
                        isSteamLaunchInProgress: state.2,
                        isStandardSteamLaunchReserved: state.3
                    )
            )
        }
    }

    func testRendererPresentationContractReturnsLocalizationKeysOnly() {
        let cases: [(SteamGraphicsBackendIdentifier, String)] = [
            (.d3dMetal, SteamRendererPolicySelection.d3dMetal.labelKey),
            (.d3dMetalNVIDIA, SteamRendererPolicySelection.d3dMetalNVIDIA.labelKey),
            (.dxmt, SteamRendererPolicySelection.dxmt.labelKey),
            (.d9vk, SteamRendererPolicySelection.d9vk.labelKey),
            (.dxvk, SteamRendererPolicySelection.vulkan.labelKey)
        ]
        for (identifier, labelKey) in cases {
            XCTAssertEqual(
                CompatibilitySteamLaunchOptionLabelPolicy.rendererLabelKey(
                    identifier
                ),
                labelKey
            )
        }
        XCTAssertEqual(
            CompatibilitySteamLaunchOptionLabelPolicy.rendererLabelKey(
                SteamGraphicsBackendIdentifier(rawValue: "legacy-renderer")!
            ),
            "지원되지 않는 이전 저장 값"
        )
    }

    @MainActor
    func testFreshInstallPointerOnlyProtectionAllowsEveryAuthorizationStatus() {
        let appState = AppState()
        let defaultPolicy = GameInputProtectionPolicy(
            modifierMap: appState.gameInputModifierMap,
            blockAppWindowManagementShortcuts:
                appState.blocksGameAppWindowManagementShortcuts,
            blockAppSwitchingShortcuts:
                appState.blocksGameAppSwitchingShortcuts,
            blockMissionControlSpaceShortcuts:
                appState.blocksGameMissionControlSpaceShortcuts,
            blockDefaultScreenshotShortcuts:
                appState.blocksGameScreenshotShortcuts,
            hidePointerWhileManagedGameFrontmost:
                appState.hidesPointerWhileManagedGameFrontmost
        )
        XCTAssertFalse(defaultPolicy.requiresEventTap)
        XCTAssertTrue(defaultPolicy.hidePointerWhileManagedGameFrontmost)
        XCTAssertTrue(defaultPolicy.isActive)

        let statuses: [GameInputProtectionAuthorizationStatus] = [
            .authorized,
            .accessibilityRequired,
            .inputMonitoringRequired,
            .accessibilityAndInputMonitoringRequired
        ]
        for status in statuses {
            XCTAssertNil(
                SteamLaunchGameInputProtectionAdmissionPolicy
                    .blockerLocalizationKey(
                        policy: defaultPolicy,
                        authorizationStatus: status
                    )
            )
        }
    }

    func testExplicitEventTapProtectionReportsUnauthorizedLaunchAdvisory() {
        let eventTapPolicy = GameInputProtectionPolicy(
            modifierMap: .recommended
        )
        XCTAssertTrue(eventTapPolicy.requiresEventTap)

        for status in [
            GameInputProtectionAuthorizationStatus.accessibilityRequired,
            .inputMonitoringRequired,
            .accessibilityAndInputMonitoringRequired
        ] {
            let advisory = SteamLaunchGameInputProtectionAdmissionPolicy
                .blockerLocalizationKey(
                    policy: eventTapPolicy,
                    authorizationStatus: status
                )
            XCTAssertTrue(
                advisory?.contains("Steam 실행은 계속합니다") == true
            )
        }
        XCTAssertNil(
            SteamLaunchGameInputProtectionAdmissionPolicy
                .blockerLocalizationKey(
                    policy: eventTapPolicy,
                    authorizationStatus: .authorized
                )
        )
    }

    func testPointerOnlyInputProtectionDoesNotRequireTCCAdmission() {
        let pointerOnlyPolicy = GameInputProtectionPolicy(
            hidePointerWhileManagedGameFrontmost: true
        )
        XCTAssertFalse(pointerOnlyPolicy.requiresEventTap)
        XCTAssertTrue(pointerOnlyPolicy.requiresManagedTarget)

        for status in [
            GameInputProtectionAuthorizationStatus.accessibilityRequired,
            .inputMonitoringRequired,
            .accessibilityAndInputMonitoringRequired
        ] {
            XCTAssertNil(
                SteamLaunchGameInputProtectionAdmissionPolicy
                    .blockerLocalizationKey(
                        policy: pointerOnlyPolicy,
                        authorizationStatus: status
                    )
            )
        }
    }

    func testGameInputPrivacyPaneRoutingMatchesMissingGrants() throws {
        XCTAssertEqual(
            GameInputProtectionPrivacyPane.requiredPanes(for: .authorized),
            []
        )
        XCTAssertEqual(
            GameInputProtectionPrivacyPane.requiredPanes(
                for: .accessibilityRequired
            ),
            [.accessibility]
        )
        XCTAssertEqual(
            GameInputProtectionPrivacyPane.requiredPanes(
                for: .inputMonitoringRequired
            ),
            [.inputMonitoring]
        )
        XCTAssertEqual(
            GameInputProtectionPrivacyPane.requiredPanes(
                for: .accessibilityAndInputMonitoringRequired
            ),
            [.accessibility, .inputMonitoring]
        )
        XCTAssertTrue(
            GameInputProtectionAuthorizationStatus.authorized
                .isAuthorized(for: .accessibility)
        )
        XCTAssertTrue(
            GameInputProtectionAuthorizationStatus.authorized
                .isAuthorized(for: .inputMonitoring)
        )
        XCTAssertFalse(
            GameInputProtectionAuthorizationStatus.accessibilityRequired
                .isAuthorized(for: .accessibility)
        )
        XCTAssertTrue(
            GameInputProtectionAuthorizationStatus.accessibilityRequired
                .isAuthorized(for: .inputMonitoring)
        )
        XCTAssertTrue(
            GameInputProtectionAuthorizationStatus.inputMonitoringRequired
                .isAuthorized(for: .accessibility)
        )
        XCTAssertFalse(
            GameInputProtectionAuthorizationStatus.inputMonitoringRequired
                .isAuthorized(for: .inputMonitoring)
        )
        for pane in GameInputProtectionPrivacyPane.allCases {
            let url = try XCTUnwrap(pane.settingsURL)
            XCTAssertEqual(url.scheme, "x-apple.systempreferences")
            XCTAssertFalse(url.absoluteString.isEmpty)
        }
    }

    func testCanonicalManifestMountSelectionIsUniqueAndPathBoundarySafe() {
        let root = CompatibilityManifestMountCandidate(
            id: "root",
            path: "/Volumes/Steam",
            bookmark: Data("root-bookmark".utf8)
        )
        let nested = CompatibilityManifestMountCandidate(
            id: "nested",
            path: "/Volumes/Steam/SteamLibrary",
            bookmark: Data("nested-bookmark".utf8)
        )
        let emptyBookmark = CompatibilityManifestMountCandidate(
            id: "empty",
            path: "/Volumes/Other",
            bookmark: Data()
        )

        XCTAssertEqual(
            CompatibilityManifestMountSelectionPolicy.matchingCandidates(
                libraryPath: "/Volumes/Steam",
                candidates: [root]
            ).map(\.id),
            ["root"]
        )
        XCTAssertEqual(
            CompatibilityManifestMountSelectionPolicy.matchingCandidates(
                libraryPath: "/Volumes/Steam/SteamLibrary/steamapps",
                candidates: [root]
            ).map(\.id),
            ["root"]
        )
        XCTAssertTrue(
            CompatibilityManifestMountSelectionPolicy.matchingCandidates(
                libraryPath: "/Volumes/Steam2/SteamLibrary",
                candidates: [root]
            ).isEmpty
        )
        XCTAssertTrue(
            CompatibilityManifestMountSelectionPolicy.matchingCandidates(
                libraryPath: "/Volumes/Other",
                candidates: [emptyBookmark]
            ).isEmpty
        )
        XCTAssertEqual(
            CompatibilityManifestMountSelectionPolicy.matchingCandidates(
                libraryPath: "/Volumes/Steam/SteamLibrary/steamapps",
                candidates: [root, nested]
            ).map(\.id),
            ["root", "nested"]
        )
        XCTAssertTrue(
            CompatibilityManifestMountSelectionPolicy.matchingCandidates(
                libraryPath: "/Volumes/Unapproved/SteamLibrary",
                candidates: [root, nested]
            ).isEmpty
        )
    }

    func testCanonicalManifestMountPreparationRejectsStaleAndRevokedBookmarks()
        async throws
    {
        let mount = CompatibilityManifestMountCandidate(
            id: "canonical",
            path: "/Volumes/Steam",
            bookmark: Data("canonical-bookmark".utf8)
        )
        let libraryPath = "/Volumes/Steam/SteamLibrary"
        let provider = TestManifestRootAuthorizationProvider()

        let staleService = CompatibilityManifestRootPreparationService(
            authorizationProvider: provider,
            selectionValidator: { url, _ in
                SteamStorageValidatedSelection(
                    root: url,
                    bookmark: Data("child-bookmark".utf8),
                    resolvedURL: url
                )
            },
            bookmarkResolver: { _ in
                SecurityScopedBookmarkResolvedURL(
                    url: URL(fileURLWithPath: mount.path, isDirectory: true),
                    isStale: true
                )
            }
        )
        do {
            _ = try await staleService.prepareLibraryRoot(
                libraryPath: libraryPath,
                mount: mount
            )
            XCTFail("A stale canonical mount bookmark became ready")
        } catch {
            XCTAssertEqual(
                error as? CompatibilityManifestRootAuthorizationErrorV1,
                .staleBookmark
            )
        }

        let revokedService = CompatibilityManifestRootPreparationService(
            authorizationProvider: provider,
            selectionValidator: { url, _ in
                SteamStorageValidatedSelection(
                    root: url,
                    bookmark: Data("child-bookmark".utf8),
                    resolvedURL: url
                )
            },
            bookmarkResolver: { _ in
                SecurityScopedBookmarkResolvedURL(
                    url: URL(fileURLWithPath: mount.path, isDirectory: true),
                    isStale: false
                )
            },
            securityScopeStarter: { _ in false }
        )
        do {
            _ = try await revokedService.prepareLibraryRoot(
                libraryPath: libraryPath,
                mount: mount
            )
            XCTFail("A revoked canonical mount bookmark became ready")
        } catch {
            XCTAssertEqual(
                error as? CompatibilityManifestRootAuthorizationErrorV1,
                .securityScopeDenied
            )
        }
    }

    func testCanonicalMountPreparationProbesChildAndReturnsTransientBookmark()
        async throws
    {
        let probe = ManifestRootPreparationProbe()
        let canonicalBookmark = Data("canonical-mount-bookmark".utf8)
        let transientBookmark = Data("transient-library-bookmark".utf8)
        let mount = CompatibilityManifestMountCandidate(
            id: "canonical",
            path: "/Volumes/Steam",
            bookmark: canonicalBookmark
        )
        let libraryPath = "/Volumes/Steam/SteamLibrary"
        let service = CompatibilityManifestRootPreparationService(
            authorizationProvider: TestManifestRootAuthorizationProvider(),
            selectionValidator: { url, requiresScope in
                probe.recordValidation(url: url, requiresScope: requiresScope)
                return SteamStorageValidatedSelection(
                    root: url,
                    bookmark: transientBookmark,
                    resolvedURL: url
                )
            },
            bookmarkResolver: { bookmark in
                probe.recordResolvedBookmark(bookmark)
                return SecurityScopedBookmarkResolvedURL(
                    url: URL(fileURLWithPath: mount.path, isDirectory: true),
                    isStale: false
                )
            },
            securityScopeStarter: { url in
                probe.recordScopeStart(url)
                return true
            },
            securityScopeStopper: { url in
                probe.recordScopeStop(url)
            }
        )

        let prepared = try await service.prepareLibraryRoot(
            libraryPath: libraryPath,
            mount: mount
        )
        let snapshot = probe.snapshot()
        XCTAssertEqual(prepared.securityScopedBookmark, transientBookmark)
        XCTAssertEqual(snapshot.resolvedBookmark, canonicalBookmark)
        XCTAssertEqual(snapshot.validatedURL?.path, libraryPath)
        XCTAssertEqual(snapshot.validationRequiredScope, false)
        XCTAssertEqual(snapshot.startedScopeURL?.path, mount.path)
        XCTAssertEqual(snapshot.stoppedScopeURL?.path, mount.path)
    }

    func testEverySupportedGraphicsBackendProjectsExactlyAndExplicitGameModeOffStaysStandard()
        async throws
    {
        let authorization = try await manifestAuthorization()
        let cases: [(SteamGraphicsBackendIdentifier, SteamRendererPolicySelection)] = [
            (.d3dMetal, .d3dMetal),
            (.d3dMetalNVIDIA, .d3dMetalNVIDIA),
            (.dxmt, .dxmt),
            (.d9vk, .d9vk),
            (.dxvk, .vulkan)
        ]

        XCTAssertEqual(recipe.supportedOptions.graphicsBackends, cases.map(\.0))

        for (graphicsBackend, rendererSelection) in cases {
            var oneLaunchOverride = CompatibilitySteamLaunchOneLaunchOverrideV1(
                identity: recipe.identity
            )
            oneLaunchOverride.graphicsBackend = graphicsBackend
            oneLaunchOverride.gameModeEnabled = false

            let request = try SteamCompatibilityLaunchResolverV1.resolve(
                recipe: recipe,
                manifestRootAuthorization: authorization,
                savedPreference: nil,
                oneLaunchOverride: oneLaunchOverride,
                capabilities: .supporting(recipe: recipe),
                transactionID: UUID()
            )
            let projection = try SteamManagerCompatibilityLaunchRequestMapperV1.projection(
                for: request
            )

            XCTAssertEqual(request.snapshot.graphicsBackend.value, graphicsBackend)
            XCTAssertEqual(
                request.snapshot.graphicsBackend.provenance,
                .oneLaunchOverride
            )
            XCTAssertFalse(request.snapshot.gameModeEnabled.value)
            XCTAssertEqual(
                request.snapshot.gameModeEnabled.provenance,
                .oneLaunchOverride
            )
            XCTAssertEqual(projection.rendererSelection, rendererSelection)
            XCTAssertEqual(projection.gameModePolicy, .standard)
        }
    }

    func testCurrentReleaseFrameGenerationResolvesOnlyForNVIDIAD3DMetal()
        async throws
    {
        let authorization = try await manifestAuthorization()
        for backend in recipe.supportedOptions.graphicsBackends {
            var oneLaunchOverride = CompatibilitySteamLaunchOneLaunchOverrideV1(
                identity: recipe.identity
            )
            oneLaunchOverride.graphicsBackend = backend
            oneLaunchOverride.frameGenerationConfiguration =
                FrameGenerationConfiguration(
                    isEnabled: true,
                    targetFrameRate: .fps120,
                    isFrameCheckEnabled: true
                )

            do {
                let request = try SteamCompatibilityLaunchResolverV1.resolve(
                    recipe: recipe,
                    manifestRootAuthorization: authorization,
                    savedPreference: nil,
                    oneLaunchOverride: oneLaunchOverride,
                    capabilities: .supporting(recipe: recipe),
                    transactionID: UUID()
                )
                XCTAssertEqual(backend, .d3dMetalNVIDIA)
                let projection = try SteamManagerCompatibilityLaunchRequestMapperV1
                    .projection(for: request)
                XCTAssertEqual(projection.rendererSelection, .d3dMetalNVIDIA)
                XCTAssertTrue(projection.frameGenerationConfiguration.isEnabled)
            } catch {
                guard backend != .d3dMetalNVIDIA else { throw error }
                XCTAssertEqual(
                    error as? FrameGenerationConfigurationError,
                    .d3dMetalNVIDIARendererRequired
                )
            }
        }
    }

    func testEverySupportedNetworkAudioAndVideoMemoryValueResolvesAndProjectsExactly()
        async throws
    {
        let authorization = try await manifestAuthorization()
        let networkCases: [
            (SteamNetworkPolicyIdentifier, SteamNetworkCompatibilitySelection)
        ] = [
            (.standard, .standard),
            (.wifiIdentity, .wifiIdentity),
            (.ethernetIdentity, .ethernetIdentity)
        ]
        let audioCases: [
            (SteamAudioInputPolicyIdentifier, SteamAudioInputSelection)
        ] = [
            (.disabled, .disabled),
            (.enabled, .enabled)
        ]
        let videoMemoryCases: [
            (SteamVideoMemoryPolicyIdentifier, SteamVideoMemorySelection)
        ] = [
            (.automatic, .automatic),
            (.gb2, .gb2),
            (.gb4, .gb4),
            (.gb8, .gb8),
            (.gb12, .gb12),
            (.gb16, .gb16)
        ]

        XCTAssertEqual(recipe.supportedOptions.networkPolicies, networkCases.map(\.0))
        XCTAssertEqual(recipe.supportedOptions.audioInputPolicies, audioCases.map(\.0))
        XCTAssertEqual(
            recipe.supportedOptions.videoMemoryPolicies,
            videoMemoryCases.map(\.0)
        )

        for (networkPolicy, expectedNetwork) in networkCases {
            for (audioInputPolicy, expectedAudio) in audioCases {
                for (videoMemoryPolicy, expectedVideoMemory) in videoMemoryCases {
                    var oneLaunchOverride = CompatibilitySteamLaunchOneLaunchOverrideV1(
                        identity: recipe.identity
                    )
                    oneLaunchOverride.networkPolicy = networkPolicy
                    oneLaunchOverride.audioInputPolicy = audioInputPolicy
                    oneLaunchOverride.videoMemoryPolicy = videoMemoryPolicy

                    let request = try SteamCompatibilityLaunchResolverV1.resolve(
                        recipe: recipe,
                        manifestRootAuthorization: authorization,
                        savedPreference: nil,
                        oneLaunchOverride: oneLaunchOverride,
                        capabilities: .supporting(recipe: recipe),
                        transactionID: UUID()
                    )
                    let projection = try SteamManagerCompatibilityLaunchRequestMapperV1
                        .projection(for: request)

                    XCTAssertEqual(request.snapshot.networkPolicy.value, networkPolicy)
                    XCTAssertEqual(request.snapshot.audioInputPolicy.value, audioInputPolicy)
                    XCTAssertEqual(request.snapshot.videoMemoryPolicy.value, videoMemoryPolicy)
                    XCTAssertEqual(
                        request.snapshot.networkPolicy.provenance,
                        .oneLaunchOverride
                    )
                    XCTAssertEqual(
                        request.snapshot.audioInputPolicy.provenance,
                        .oneLaunchOverride
                    )
                    XCTAssertEqual(
                        request.snapshot.videoMemoryPolicy.provenance,
                        .oneLaunchOverride
                    )
                    XCTAssertEqual(projection.networkSelection, expectedNetwork)
                    XCTAssertEqual(projection.audioInputSelection, expectedAudio)
                    XCTAssertEqual(projection.videoMemorySelection, expectedVideoMemory)
                    XCTAssertEqual(
                        projection.videoMemorySizeMB,
                        expectedVideoMemory.resolvedSizeMB()
                    )
                }
            }
        }
    }

    func testRecipeRejectsAnIncompletePresentationDescriptorSet() throws {
        XCTAssertThrowsError(
            try SteamCompatibilityLaunchProfileRecipeV1(
                identity: recipe.identity,
                displayName: recipe.displayName,
                initialSelections: recipe.initialSelections,
                recommendations: recipe.recommendations,
                supportedOptions: recipe.supportedOptions,
                orderedOptionDescriptors: Array(recipe.orderedOptionDescriptors.dropLast()),
                automaticRequiredPolicies: recipe.automaticRequiredPolicies
            )
        )
    }

    func testRecipeAcceptsACompleteReadOnlySummaryPlacementWithoutAddingKinds() throws {
        var descriptors = recipe.orderedOptionDescriptors
        let keyboardIndex = try XCTUnwrap(
            descriptors.firstIndex(where: { $0.kind == .keyboardMapping })
        )
        descriptors[keyboardIndex] = CompatibilitySteamLaunchOptionDescriptorV1(
            kind: .keyboardMapping,
            placement: .readOnlySummary
        )
        let projected = try SteamCompatibilityLaunchProfileRecipeV1(
            identity: recipe.identity,
            displayName: recipe.displayName,
            initialSelections: recipe.initialSelections,
            recommendations: recipe.recommendations,
            supportedOptions: recipe.supportedOptions,
            orderedOptionDescriptors: descriptors,
            automaticRequiredPolicies: recipe.automaticRequiredPolicies
        )

        XCTAssertEqual(projected.orderedOptionDescriptors.count, descriptors.count)
        XCTAssertEqual(
            projected.orderedOptionDescriptors[keyboardIndex].placement,
            .readOnlySummary
        )
    }

    func testPreferenceCanonicalRoundTripPreservesExplicitSelections() throws {
        var selections = recipe.initialSelections
        selections.gameModeEnabled = false
        selections.heapZeroMemoryEnabled = false
        selections.graphicsBackend = try SteamGraphicsBackendIdentifier.validated("dxvk")
        selections.networkPolicy = try SteamNetworkPolicyIdentifier.validated("ethernet-identity")
        selections.audioInputPolicy = .enabled
        selections.videoMemoryPolicy = try SteamVideoMemoryPolicyIdentifier.validated("gb12")

        let preference = try CompatibilitySteamLaunchPreferencePayloadV1(
            identity: recipe.identity,
            selections: selections
        )
        let payload = try preference.canonicalPayload()
        let decoded = try CompatibilitySteamLaunchPreferencePayloadV1(
            canonicalPayload: payload
        )

        XCTAssertEqual(decoded, preference)
        XCTAssertEqual(try decoded.canonicalPayload(), payload)
        XCTAssertEqual(try decoded.canonicalDigest, try preference.canonicalDigest)
        XCTAssertFalse(decoded.selections.gameModeEnabled)
        XCTAssertFalse(decoded.selections.heapZeroMemoryEnabled)
    }

    func testPreferenceCanonicalRoundTripPreservesFrameGenerationAndFrameCheck()
        throws
    {
        var selections = recipe.initialSelections
        selections.graphicsBackend = .d3dMetalNVIDIA
        selections.frameGenerationConfiguration = FrameGenerationConfiguration(
            isEnabled: true,
            targetFrameRate: .fps120,
            isFrameCheckEnabled: true
        )
        let preference = try CompatibilitySteamLaunchPreferencePayloadV1(
            identity: recipe.identity,
            selections: selections
        )

        let decoded = try CompatibilitySteamLaunchPreferencePayloadV1(
            canonicalPayload: preference.canonicalPayload()
        )

        XCTAssertEqual(
            decoded.selections.frameGenerationConfiguration,
            selections.frameGenerationConfiguration
        )

        selections.frameGenerationConfiguration.isFrameCheckEnabled = false
        let explicitFrameCheckOffPreference = try
            CompatibilitySteamLaunchPreferencePayloadV1(
                identity: recipe.identity,
                selections: selections
            )
        let explicitFrameCheckOffDecoded = try
            CompatibilitySteamLaunchPreferencePayloadV1(
                canonicalPayload: explicitFrameCheckOffPreference
                    .canonicalPayload()
            )
        XCTAssertTrue(
            explicitFrameCheckOffDecoded.selections
                .frameGenerationConfiguration.isEnabled
        )
        XCTAssertFalse(
            explicitFrameCheckOffDecoded.selections
                .frameGenerationConfiguration.isFrameCheckEnabled
        )
    }

    func testHiddenD3DMetalPreferenceNormalizesWithoutDroppingEnvelope()
        throws
    {
        var selections = recipe.initialSelections
        selections.graphicsBackend = .d3dMetal
        selections.frameGenerationConfiguration = .off
        let payload = try CompatibilitySteamLaunchPreferencePayloadV1(
            identity: recipe.identity,
            selections: selections
        )
        let saved = try CompatibilitySteamLaunchPreferenceEnvelopeV1(
            payload: payload,
            payloadDigest: payload.canonicalDigest,
            generation: 7,
            persistenceRevision: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        var normalizationOverride = CompatibilitySteamLaunchOneLaunchOverrideV1(
            identity: recipe.identity
        )
        normalizationOverride.graphicsBackend = .d3dMetalNVIDIA

        let resolved = try SteamCompatibilityLaunchResolverV1.resolveDraft(
            recipe: recipe,
            savedPreference: saved,
            oneLaunchOverride: normalizationOverride
        )

        XCTAssertEqual(resolved.graphicsBackend.value, .d3dMetalNVIDIA)
        XCTAssertEqual(resolved.graphicsBackend.provenance, .oneLaunchOverride)
        XCTAssertEqual(
            resolved.frameGenerationConfiguration.value,
            .off
        )
        XCTAssertEqual(
            resolved.frameGenerationConfiguration.provenance,
            .savedPreference
        )
        XCTAssertEqual(saved.generation, 7)
    }

    func testMigrationPreservesSnapshotFieldsAndInitializesOnlyNewSelectionFromRecipe() throws {
        let permutation = try ModifierKeyPermutation(
            command: .windows,
            option: .control,
            control: .alt
        )
        let snapshot = try SteamLaunchConfigurationSnapshot(
            identity: .compatibility(recipe.identity),
            graphicsBackend: SteamGraphicsBackendIdentifier.validated("dxmt"),
            networkPolicy: SteamNetworkPolicyIdentifier.validated("wifi-identity"),
            audioInputPolicy: .enabled,
            synchronizationPolicy: .automatic,
            videoMemoryPolicy: SteamVideoMemoryPolicyIdentifier.validated("gb8"),
            gameModeEnabled: false,
            fpsCursorPolicy: .fpsRelativeCaptureBeta,
            controllerPolicy: .macOSSyntheticHID,
            keyboardMapping: KeyboardMappingPreference(
                preset: .custom,
                customPermutation: permutation
            )
        )

        let migrated = try SteamCompatibilitySnapshotV1MigrationAdapter.preference(
            from: snapshot,
            recipe: recipe
        )

        XCTAssertEqual(migrated.identity, recipe.identity)
        XCTAssertEqual(migrated.selections.graphicsBackend, snapshot.graphicsBackend)
        XCTAssertEqual(migrated.selections.networkPolicy, snapshot.networkPolicy)
        XCTAssertEqual(migrated.selections.audioInputPolicy, snapshot.audioInputPolicy)
        XCTAssertEqual(migrated.selections.synchronizationPolicy, snapshot.synchronizationPolicy)
        XCTAssertEqual(migrated.selections.videoMemoryPolicy, snapshot.videoMemoryPolicy)
        XCTAssertEqual(migrated.selections.gameModeEnabled, snapshot.gameModeEnabled)
        XCTAssertEqual(migrated.selections.fpsCursorPolicy, snapshot.fpsCursorPolicy)
        XCTAssertEqual(migrated.selections.controllerPolicy, snapshot.controllerPolicy)
        XCTAssertEqual(migrated.selections.keyboardMapping, snapshot.keyboardMapping)
        XCTAssertEqual(
            migrated.selections.heapZeroMemoryEnabled,
            recipe.initialSelections.heapZeroMemoryEnabled
        )
    }

    func testMigrationRejectsMismatchedRecipeIdentity() throws {
        let otherIdentity = try SteamCompatibilityProfileIdentity(
            steamAppID: "553851",
            profileID: recipe.identity.profileID,
            recipeRevision: recipe.identity.recipeRevision
        )
        let snapshot = try SteamLaunchConfigurationSnapshot(
            identity: .compatibility(otherIdentity)
        )

        XCTAssertThrowsError(
            try SteamCompatibilitySnapshotV1MigrationAdapter.preference(
                from: snapshot,
                recipe: recipe
            )
        )
    }

    func testResolverPrecedenceProvenanceAndAutomaticPolicy() async throws {
        var savedSelections = recipe.initialSelections
        savedSelections.graphicsBackend = try SteamGraphicsBackendIdentifier.validated("dxmt")
        savedSelections.gameModeEnabled = false
        savedSelections.heapZeroMemoryEnabled = false
        let savedPayload = try CompatibilitySteamLaunchPreferencePayloadV1(
            identity: recipe.identity,
            selections: savedSelections
        )
        let saved = try CompatibilitySteamLaunchPreferenceEnvelopeV1(
            payload: savedPayload,
            payloadDigest: savedPayload.canonicalDigest,
            generation: 4,
            persistenceRevision: UUID(
                uuidString: "12345678-1234-1234-1234-123456789abc"
            )!,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        var override = CompatibilitySteamLaunchOneLaunchOverrideV1(
            identity: recipe.identity
        )
        override.graphicsBackend = .d3dMetal
        override.heapZeroMemoryEnabled = true

        let request = try SteamCompatibilityLaunchResolverV1.resolve(
            recipe: recipe,
            manifestRootAuthorization: try await manifestAuthorization(),
            savedPreference: saved,
            oneLaunchOverride: override,
            capabilities: .supporting(recipe: recipe),
            transactionID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )

        XCTAssertEqual(request.snapshot.graphicsBackend.value, .d3dMetal)
        XCTAssertEqual(request.snapshot.graphicsBackend.provenance, .oneLaunchOverride)
        XCTAssertFalse(request.snapshot.gameModeEnabled.value)
        XCTAssertEqual(request.snapshot.gameModeEnabled.provenance, .savedPreference)
        XCTAssertTrue(request.snapshot.heapZeroMemoryEnabled.value)
        XCTAssertEqual(request.snapshot.heapZeroMemoryEnabled.provenance, .oneLaunchOverride)
        XCTAssertEqual(
            request.snapshot.automaticRequiredPolicies.map(\.provenance),
            [.automaticRequired]
        )
        XCTAssertEqual(request.canonicalDigest.count, 64)
    }

    func testAutomaticPolicyRemovalAndUnsupportedCapabilityFailClosed() async throws {
        let authorization = try await manifestAuthorization()
        var removal = CompatibilitySteamLaunchOneLaunchOverrideV1(identity: recipe.identity)
        removal.replacementAutomaticPolicyRuleIDs = []
        XCTAssertThrowsError(
            try SteamCompatibilityLaunchResolverV1.resolve(
                recipe: recipe,
                manifestRootAuthorization: authorization,
                savedPreference: nil,
                oneLaunchOverride: removal,
                capabilities: .supporting(recipe: recipe),
                transactionID: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error as? SteamCompatibilityLaunchProfileErrorV1,
                .attemptedAutomaticPolicyRemoval
            )
        }

        let unsupported = CompatibilitySteamLaunchRuntimeCapabilitiesV1(
            supportedProfileContractVersions: [recipe.contractVersion],
            supportedRecipeSchemaVersions: [recipe.schemaVersion],
            supportedGraphicsBackends: [],
            supportedNetworkPolicies: Set(recipe.supportedOptions.networkPolicies),
            supportedAudioInputPolicies: Set(recipe.supportedOptions.audioInputPolicies),
            supportedSynchronizationPolicies: Set(recipe.supportedOptions.synchronizationPolicies),
            supportedVideoMemoryPolicies: Set(recipe.supportedOptions.videoMemoryPolicies),
            supportsGameModeSelection: true,
            supportsHeapZeroMemorySelection: true,
            supportedFPSCursorPolicies: Set(recipe.supportedOptions.fpsCursorPolicies),
            supportedControllerPolicies: Set(recipe.supportedOptions.controllerPolicies),
            supportedKeyboardPresets: Set(recipe.supportedOptions.keyboardPresets),
            supportsCustomKeyboardPermutation: false,
            supportedProcessMatchers: [.gameGuardFamilyASCIIComponentOrFinalStem],
            supportedProcessPolicyActions: [.excludeRendererEnvironmentAndRendererDLLOverrides]
        )
        XCTAssertThrowsError(
            try SteamCompatibilityLaunchResolverV1.resolve(
                recipe: recipe,
                manifestRootAuthorization: authorization,
                savedPreference: nil,
                capabilities: unsupported,
                transactionID: UUID()
            )
        )
    }

    func testMatcherRequiresExactASCIINameAndProvenRoot() async throws {
        let authorization = try await manifestAuthorization()
        let rule = try XCTUnwrap(recipe.automaticRequiredPolicies.first)
        let digest = authorization.authorizationDigest

        XCTAssertTrue(matches(["bin", "GameGuard", "helper.exe"], digest, rule, authorization))
        XCTAssertTrue(matches(["bin", "gAmEgUaRd.exe"], digest, rule, authorization))
        XCTAssertFalse(matches(["bin", "GameGuardHelper.exe"], digest, rule, authorization))
        XCTAssertFalse(matches(["bin", "preGameGuard.exe"], digest, rule, authorization))
        XCTAssertFalse(matches(["bin", "GameGuard.backup.exe"], digest, rule, authorization))
        XCTAssertFalse(matches(["bin", "ＧａｍｅＧｕａｒｄ.exe"], digest, rule, authorization))
        XCTAssertFalse(matches(["..", "GameGuard.exe"], digest, rule, authorization))
        XCTAssertFalse(
            CompatibilityAutomaticProcessMatcherEvaluatorV1.matches(
                rule: rule,
                rootAuthorization: authorization,
                containment: .unresolved
            )
        )
        XCTAssertFalse(
            CompatibilityAutomaticProcessMatcherEvaluatorV1.matches(
                rule: rule,
                rootAuthorization: authorization,
                containment: .escapedRoot
            )
        )
        XCTAssertFalse(matches(["GameGuard.exe"], String(repeating: "0", count: 64), rule, authorization))
    }

    func testResolvedOnlyLaunchRecordProjectionHasNoApplicationEvidence() async throws {
        let authorization = try await manifestAuthorization()
        let request = try SteamCompatibilityLaunchResolverV1.resolve(
            recipe: recipe,
            manifestRootAuthorization: authorization,
            savedPreference: nil,
            capabilities: .supporting(recipe: recipe),
            transactionID: UUID()
        )
        let projection = try CompatibilityLaunchRecordProjectionV1(
            request: request,
            receipt: nil
        )

        XCTAssertEqual(projection.identity, recipe.identity)
        XCTAssertEqual(projection.resolvedRequestDigest, request.canonicalDigest)
        XCTAssertNil(projection.providerReceiptID)
        XCTAssertNil(projection.appliedRequestDigest)
        XCTAssertNil(projection.capturedBaselineDigest)
        XCTAssertNil(projection.restoredBaselineDigest)
    }

    func testUnavailableProviderNeverProducesCapabilitiesOrReceipt() async {
        let provider = UnavailableCompatibilityLaunchRuntimeProviderV1()
        do {
            _ = try await provider.capabilities()
            XCTFail("Unavailable provider returned capabilities")
        } catch {
            XCTAssertEqual(
                error as? CompatibilityLaunchRuntimeProviderUnavailableErrorV1,
                .unavailable
            )
        }
    }

    func testUnavailableRootAuthorizationProviderFailsClosed() async throws {
        let provider = UnavailableCompatibilityManifestRootAuthorizationProviderV1()
        do {
            _ = try await provider.resolveAndPinManifestRoot(
                bookmark: unresolvedBookmark("unavailable")
            )
            XCTFail("Unavailable root provider returned an authorization")
        } catch {
            XCTAssertEqual(
                error as? CompatibilityManifestRootAuthorizationErrorV1,
                .unavailable
            )
        }
    }

    func testInvalidAndStaleBookmarksFailBeforeRuntimeCapabilities() async throws {
        XCTAssertThrowsError(
            try CompatibilityUnresolvedManifestRootBookmarkV1(
                securityScopedBookmark: Data()
            )
        )

        let runtime = await RuntimeProviderProbe(recipe: recipe)
        let coordinator = await SteamCompatibilityLaunchCoordinatorV1(
            manifestRootAuthorizationProvider: RejectingManifestRootAuthorizationProvider(
                error: .staleBookmark
            ),
            runtimeProvider: runtime
        )
        do {
            _ = try await coordinator.prepareSteamSession(
                recipe: recipe,
                unresolvedManifestRootBookmark: unresolvedBookmark("stale"),
                savedPreference: nil
            )
            XCTFail("A stale bookmark reached runtime capabilities")
        } catch {
            XCTAssertEqual(
                error as? CompatibilityManifestRootAuthorizationErrorV1,
                .staleBookmark
            )
        }
        let capabilityCalls = await runtime.capabilityCalls
        XCTAssertEqual(capabilityCalls, 0)
    }

    func testMismatchedAuthorizationProviderOutputBlocksBeforeRuntimeCapabilities() async throws {
        let selected = try unresolvedBookmark("selected")
        let other = try unresolvedBookmark("other")
        let runtime = await RuntimeProviderProbe(recipe: recipe)
        let coordinator = await SteamCompatibilityLaunchCoordinatorV1(
            manifestRootAuthorizationProvider: TestManifestRootAuthorizationProvider(
                substitutedBookmark: other
            ),
            runtimeProvider: runtime
        )

        do {
            _ = try await coordinator.prepareSteamSession(
                recipe: recipe,
                unresolvedManifestRootBookmark: selected,
                savedPreference: nil
            )
            XCTFail("Mismatched root authorization reached the runtime")
        } catch {
            XCTAssertEqual(
                error as? CompatibilityManifestRootAuthorizationErrorV1,
                .providerOutputMismatch
            )
        }
        let capabilityCalls = await runtime.capabilityCalls
        XCTAssertEqual(capabilityCalls, 0)
    }

    func testRuntimeEvidenceAllowsCaptureBeforeApplyAndEnforcesLifecycleTruth() throws {
        let requestDigest = String(repeating: "a", count: 64)
        let baselineDigest = String(repeating: "b", count: 64)
        let otherBaselineDigest = String(repeating: "c", count: 64)

        XCTAssertNoThrow(
            try CompatibilityRuntimeApplicationEvidenceV1(
                capturedBaselineDigest: baselineDigest
            )
        )
        XCTAssertNoThrow(
            try CompatibilityRuntimeApplicationEvidenceV1(
                appliedRequestDigest: requestDigest,
                capturedBaselineDigest: baselineDigest
            )
        )
        XCTAssertNoThrow(
            try CompatibilityRuntimeApplicationEvidenceV1(
                appliedRequestDigest: requestDigest,
                capturedBaselineDigest: baselineDigest,
                restoredBaselineDigest: baselineDigest
            )
        )
        XCTAssertThrowsError(
            try CompatibilityRuntimeApplicationEvidenceV1(
                appliedRequestDigest: requestDigest
            )
        )
        XCTAssertThrowsError(
            try CompatibilityRuntimeApplicationEvidenceV1(
                capturedBaselineDigest: baselineDigest,
                restoredBaselineDigest: baselineDigest
            )
        )
        XCTAssertThrowsError(
            try CompatibilityRuntimeApplicationEvidenceV1(
                appliedRequestDigest: requestDigest,
                capturedBaselineDigest: baselineDigest,
                restoredBaselineDigest: otherBaselineDigest
            )
        )
    }

    private func unresolvedBookmark(
        _ seed: String
    ) throws -> CompatibilityUnresolvedManifestRootBookmarkV1
    {
        try CompatibilityUnresolvedManifestRootBookmarkV1(
            securityScopedBookmark: Data("opaque-bookmark-\(seed)".utf8)
        )
    }

    private func manifestAuthorization()
        async throws -> CompatibilityManifestRootAuthorizationTokenV1
    {
        try await TestManifestRootAuthorizationProvider()
            .resolveAndPinManifestRoot(
                bookmark: unresolvedBookmark("approved")
            )
    }

    private struct TestManifestRootAuthorizationProvider:
        CompatibilityManifestRootAuthorizationProviderV1
    {
        let substitutedBookmark: CompatibilityUnresolvedManifestRootBookmarkV1?

        init(
            substitutedBookmark: CompatibilityUnresolvedManifestRootBookmarkV1? = nil
        ) {
            self.substitutedBookmark = substitutedBookmark
        }

        func resolveAndPinManifestRoot(
            bookmark: CompatibilityUnresolvedManifestRootBookmarkV1
        ) async throws -> CompatibilityManifestRootAuthorizationTokenV1 {
            let source = substitutedBookmark ?? bookmark
            return try CompatibilityManifestRootAuthorizationTokenV1(
                providerID: "forgeplay.test-root-provider-v1",
                sourceBookmark: source,
                pinnedVolumeIdentifier: Data("opaque-volume-id".utf8),
                pinnedFileIdentifier: Data("opaque-file-id".utf8)
            )
        }
    }

    @MainActor
    private final class RuntimeProviderProbe:
        CompatibilityLaunchRuntimeProviderV1
    {
        private let recipe: SteamCompatibilityLaunchProfileRecipeV1
        private(set) var capabilityCalls = 0

        init(recipe: SteamCompatibilityLaunchProfileRecipeV1) {
            self.recipe = recipe
        }

        func capabilities() async throws -> CompatibilitySteamLaunchRuntimeCapabilitiesV1 {
            capabilityCalls += 1
            return .supporting(recipe: recipe)
        }

        func prepareSteamSession(
            request: ResolvedCompatibilityLaunchRequestV1
        ) async throws -> CompatibilityLaunchApplicationReceiptV1 {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "unexpected-runtime-call"
            )
        }

        func completeSteamSession(
            receipt: CompatibilityLaunchApplicationReceiptV1
        ) async throws -> CompatibilityLaunchApplicationReceiptV1 {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "unexpected-runtime-call"
            )
        }

        func completeSteamSessionForApplicationTermination(
            receipt: CompatibilityLaunchApplicationReceiptV1
        ) async throws -> CompatibilityLaunchApplicationReceiptV1 {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "unexpected-runtime-call"
            )
        }
    }

    private struct RejectingManifestRootAuthorizationProvider:
        CompatibilityManifestRootAuthorizationProviderV1
    {
        let error: CompatibilityManifestRootAuthorizationErrorV1

        func resolveAndPinManifestRoot(
            bookmark: CompatibilityUnresolvedManifestRootBookmarkV1
        ) async throws -> CompatibilityManifestRootAuthorizationTokenV1 {
            try bookmark.validate()
            throw error
        }
    }

    private final class ManifestRootPreparationProbe: @unchecked Sendable {
        struct Snapshot {
            let resolvedBookmark: Data?
            let validatedURL: URL?
            let validationRequiredScope: Bool?
            let startedScopeURL: URL?
            let stoppedScopeURL: URL?
        }

        private let lock = NSLock()
        private var resolvedBookmark: Data?
        private var validatedURL: URL?
        private var validationRequiredScope: Bool?
        private var startedScopeURL: URL?
        private var stoppedScopeURL: URL?

        func recordResolvedBookmark(_ bookmark: Data) {
            lock.lock()
            resolvedBookmark = bookmark
            lock.unlock()
        }

        func recordValidation(url: URL, requiresScope: Bool) {
            lock.lock()
            validatedURL = url
            validationRequiredScope = requiresScope
            lock.unlock()
        }

        func recordScopeStart(_ url: URL) {
            lock.lock()
            startedScopeURL = url
            lock.unlock()
        }

        func recordScopeStop(_ url: URL) {
            lock.lock()
            stoppedScopeURL = url
            lock.unlock()
        }

        func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(
                resolvedBookmark: resolvedBookmark,
                validatedURL: validatedURL,
                validationRequiredScope: validationRequiredScope,
                startedScopeURL: startedScopeURL,
                stoppedScopeURL: stoppedScopeURL
            )
        }
    }

    private func matches(
        _ components: [String],
        _ digest: String,
        _ rule: CompatibilityAutomaticProcessPolicyRuleV1,
        _ authorization: CompatibilityManifestRootAuthorizationTokenV1
    ) -> Bool {
        CompatibilityAutomaticProcessMatcherEvaluatorV1.matches(
            rule: rule,
            rootAuthorization: authorization,
            containment: .contained(
                rootAuthorizationDigest: digest,
                relativePathComponents: components
            )
        )
    }

    private enum PostDispatchAdvisoryReadbackProbeError: Error {
        case unavailable
    }
}
