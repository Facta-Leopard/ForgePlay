import Foundation
import XCTest
@testable import ForgePlay

final class SteamLaunchProfileAVXBoundaryTests: XCTestCase {
    private let recipe = SteamCompatibilityLaunchProfileCatalogV1.helldivers2

    func testProviderQuarantinesDXVKWithoutRemovingThePersistedCatalogValue() {
        let capabilities =
            SteamManagerCompatibilityLaunchRuntimeProviderV1.capabilities(
                for: SteamCompatibilityLaunchProfileCatalogV1.recipes
            )

        XCTAssertTrue(recipe.supportedOptions.graphicsBackends.contains(.dxvk))
        XCTAssertFalse(capabilities.supportedGraphicsBackends.contains(.dxvk))
        XCTAssertTrue(capabilities.supportedGraphicsBackends.contains(.d3dMetal))
        XCTAssertTrue(
            capabilities.supportedGraphicsBackends.contains(.d3dMetalNVIDIA)
        )
        XCTAssertTrue(capabilities.supportedGraphicsBackends.contains(.dxmt))
        XCTAssertTrue(capabilities.supportedGraphicsBackends.contains(.d9vk))
    }

    func testProviderAdvertisesDXVKOnlyForVerifiedRuntimeAvailability() {
        let unavailableCapabilities =
            SteamManagerCompatibilityLaunchRuntimeProviderV1.capabilities(
                for: SteamCompatibilityLaunchProfileCatalogV1.recipes,
                dxvkAvailability: .unavailable(
                    technicalDetail: "generation gate pending"
                )
            )
        let availableCapabilities =
            SteamManagerCompatibilityLaunchRuntimeProviderV1.capabilities(
                for: SteamCompatibilityLaunchProfileCatalogV1.recipes,
                dxvkAvailability: .available
            )

        XCTAssertFalse(
            unavailableCapabilities.supportedGraphicsBackends.contains(.dxvk)
        )
        XCTAssertTrue(
            availableCapabilities.supportedGraphicsBackends.contains(.dxvk)
        )
    }

    func testBuiltInKeyboardContractIsSubsetOfRealProviderCapabilities() {
        let capabilities =
            SteamManagerCompatibilityLaunchRuntimeProviderV1.capabilities(
                for: SteamCompatibilityLaunchProfileCatalogV1.recipes
            )

        XCTAssertEqual(recipe.initialSelections.keyboardMapping, .systemDefault)
        XCTAssertEqual(
            recipe.recommendations.selections.keyboardMapping,
            .systemDefault
        )
        XCTAssertTrue(
            Set(recipe.supportedOptions.keyboardPresets).isSubset(
                of: capabilities.supportedKeyboardPresets
            )
        )
        XCTAssertEqual(capabilities.supportedKeyboardPresets, [.systemDefault])
        XCTAssertTrue(
            Set(recipe.supportedOptions.fpsCursorPolicies).isSubset(
                of: capabilities.supportedFPSCursorPolicies
            )
        )
        XCTAssertTrue(
            Set(recipe.supportedOptions.controllerPolicies).isSubset(
                of: capabilities.supportedControllerPolicies
            )
        )
        XCTAssertEqual(recipe.supportedOptions.fpsCursorPolicies, [.off])
        XCTAssertEqual(recipe.supportedOptions.controllerPolicies, [.automatic])
        XCTAssertFalse(recipe.supportedOptions.supportsCustomKeyboardPermutation)
        XCTAssertFalse(capabilities.supportsCustomKeyboardPermutation)
    }

    func testScreenshotEquivalentSelectionPassesPurePrelaunchAdmission()
        async throws
    {
        var oneLaunch = CompatibilitySteamLaunchOneLaunchOverrideV1(
            identity: recipe.identity
        )
        oneLaunch.graphicsBackend = .d3dMetal
        oneLaunch.networkPolicy = .standard
        oneLaunch.audioInputPolicy = .disabled
        oneLaunch.synchronizationPolicy = .automatic
        oneLaunch.videoMemoryPolicy = .automatic
        oneLaunch.gameModeEnabled = true
        oneLaunch.fpsCursorPolicy = .off
        oneLaunch.controllerPolicy = .automatic
        oneLaunch.keyboardMapping = .systemDefault

        let request = try SteamCompatibilityLaunchResolverV1.resolve(
            recipe: recipe,
            manifestRootAuthorization: try await manifestAuthorization(),
            savedPreference: nil,
            oneLaunchOverride: oneLaunch,
            capabilities:
                SteamManagerCompatibilityLaunchRuntimeProviderV1.capabilities(
                    for: SteamCompatibilityLaunchProfileCatalogV1.recipes
                ),
            transactionID: UUID()
        )

        XCTAssertEqual(request.snapshot.graphicsBackend.value, .d3dMetal)
        XCTAssertEqual(request.snapshot.networkPolicy.value, .standard)
        XCTAssertEqual(request.snapshot.audioInputPolicy.value, .disabled)
        XCTAssertEqual(request.snapshot.synchronizationPolicy.value, .automatic)
        XCTAssertEqual(request.snapshot.videoMemoryPolicy.value, .automatic)
        XCTAssertTrue(request.snapshot.gameModeEnabled.value)
        XCTAssertEqual(request.snapshot.fpsCursorPolicy.value, .off)
        XCTAssertEqual(request.snapshot.controllerPolicy.value, .automatic)
        XCTAssertEqual(request.snapshot.keyboardMapping.value, .systemDefault)
    }

    @MainActor
    func testStandardLaunchScreenshotSelectionPassesMutationFreeAdmission()
        throws
    {
        let selection = SteamLaunchConfigurationProductSelection(
            rendererPolicySelection: .d3dMetal,
            networkSelection: .standard,
            audioInputSelection: .disabled,
            synchronizationSelection: .automatic,
            videoMemorySelection: .automatic,
            gameModePolicy: .experimentalRequiredHost,
            fpsCursorPolicy: .off,
            controllerPolicy: .automatic,
            keyboardMapping: .systemDefault
        )
        let snapshot = try SteamLaunchConfigurationProductAdapter
            .standardSnapshot(selection: selection)
        let roundTrip = try SteamLaunchConfigurationProductAdapter
            .productSelection(from: snapshot)

        XCTAssertEqual(roundTrip, selection)
        XCTAssertNoThrow(
            try SteamInputCompatibilitySession.requireSupported(
                cursorPolicy: roundTrip.fpsCursorPolicy,
                keyboardMapping: roundTrip.keyboardMapping
            )
        )
        XCTAssertNoThrow(
            try SteamControllerCompatibilitySession.requireSupported(
                policy: roundTrip.controllerPolicy,
                inventory: ControllerCompatibilityInventory(
                    macDiscoveryCount: 1,
                    uniqueMacDeviceCount: 1
                )
            )
        )
    }

    func testUnsupportedSavedAndOneLaunchKeyboardValuesFailWithExactCategory()
        async throws
    {
        let capabilities =
            SteamManagerCompatibilityLaunchRuntimeProviderV1.capabilities(
                for: SteamCompatibilityLaunchProfileCatalogV1.recipes
            )
        let authorization = try await manifestAuthorization()
        let custom = try KeyboardMappingPreference(
            preset: .custom,
            customPermutation: ModifierKeyPermutation(
                command: .windows,
                option: .alt,
                control: .control
            )
        )

        for keyboardMapping in [KeyboardMappingPreference.windowsFriendly, custom] {
            var savedSelections = recipe.initialSelections
            savedSelections.keyboardMapping = keyboardMapping
            let payload = try CompatibilitySteamLaunchPreferencePayloadV1(
                identity: recipe.identity,
                selections: savedSelections
            )
            let saved = try CompatibilitySteamLaunchPreferenceEnvelopeV1(
                payload: payload,
                payloadDigest: try payload.canonicalDigest,
                generation: 1,
                persistenceRevision: UUID(),
                createdAt: Date(timeIntervalSinceReferenceDate: 1),
                updatedAt: Date(timeIntervalSinceReferenceDate: 1)
            )
            assertUnsupportedKeyboardCategory(
                value: keyboardMapping.preset.rawValue
            ) {
                _ = try SteamCompatibilityLaunchResolverV1.resolve(
                    recipe: recipe,
                    manifestRootAuthorization: authorization,
                    savedPreference: saved,
                    capabilities: capabilities,
                    transactionID: UUID()
                )
            }

            var oneLaunch = CompatibilitySteamLaunchOneLaunchOverrideV1(
                identity: recipe.identity
            )
            oneLaunch.keyboardMapping = keyboardMapping
            assertUnsupportedKeyboardCategory(
                value: keyboardMapping.preset.rawValue
            ) {
                _ = try SteamCompatibilityLaunchResolverV1.resolve(
                    recipe: recipe,
                    manifestRootAuthorization: authorization,
                    savedPreference: nil,
                    oneLaunchOverride: oneLaunch,
                    capabilities: capabilities,
                    transactionID: UUID()
                )
            }
        }
    }

    func testRosettaAVXPolicyAcceptsOnlyAbsentOneAndZero() throws {
        XCTAssertEqual(
            try ManagedWineRosettaAVXPolicyV1.snapshot(hostOverride: nil)
                .childEnvironmentValue,
            "1"
        )
        XCTAssertEqual(
            try ManagedWineRosettaAVXPolicyV1.snapshot(hostOverride: "1")
                .childEnvironmentValue,
            "1"
        )
        XCTAssertNil(
            try ManagedWineRosettaAVXPolicyV1.snapshot(hostOverride: "0")
                .childEnvironmentValue
        )

        XCTAssertThrowsError(
            try ManagedWineRosettaAVXPolicyV1.snapshot(hostOverride: "true")
        ) { error in
            guard let runnerError = error as? SafeProcessRunnerError,
                  case .invalidRosettaAVXHostOverride("true") =
                    runnerError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(
                (error as? ForgePlayTechnicalDescribingError)?
                    .forgePlayTechnicalDescription,
                "SafeProcessRunnerError case=invalidRosettaAVXHostOverride " +
                    "category=host-environment value=true " +
                    "key=FORGEPLAY_ROSETTA_ADVERTISE_AVX"
            )
        }
    }

    func testStandardAndGameModeSpecsAcceptSameSnapshottedAVXPolicy() throws {
        for gameModePolicy in [
            SteamGameModeLaunchPolicy.standard,
            .experimentalRequiredHost
        ] {
            for hostOverride in [String?.none, "1", "0"] {
                let policy = try ManagedWineRosettaAVXPolicyV1.snapshot(
                    hostOverride: hostOverride
                )
                let pair = try commandSpecAndPolicy(
                    policy: policy,
                    gameModePolicy: gameModePolicy
                )
                let projection = try XCTUnwrap(
                    SafeProcessRunner.managedWineLaunchEnvironmentProjection(
                        from: pair.spec.environment
                    )
                )

                XCTAssertEqual(
                    pair.spec.managedWineRosettaAVXPolicy,
                    policy
                )
                XCTAssertEqual(
                    projection.rosettaAdvertiseAVX,
                    policy.childEnvironmentValue
                )
                XCTAssertNoThrow(
                    try SteamManagerCompatibilityLaunchRuntimeProviderV1
                        .requireLaunchEnvironmentProjection(
                            projection,
                            expectedRosettaAVXPolicy:
                                pair.spec.managedWineRosettaAVXPolicy,
                            policy: pair.childPolicy,
                            expectedRequestProjection:
                                pair.requestProjection
                        )
                )
            }
        }
    }

    func testStandardAndGameModeSpecsRejectDifferentExpectedAVXPolicy() throws {
        for gameModePolicy in [
            SteamGameModeLaunchPolicy.standard,
            .experimentalRequiredHost
        ] {
            let enabled = try ManagedWineRosettaAVXPolicyV1.snapshot(
                hostOverride: "1"
            )
            let disabled = try ManagedWineRosettaAVXPolicyV1.snapshot(
                hostOverride: "0"
            )
            let pair = try commandSpecAndPolicy(
                policy: enabled,
                gameModePolicy: gameModePolicy
            )
            let projection = SafeProcessRunner
                .managedWineLaunchEnvironmentProjection(
                    from: pair.spec.environment
                )

            XCTAssertThrowsError(
                try SteamManagerCompatibilityLaunchRuntimeProviderV1
                    .requireLaunchEnvironmentProjection(
                        projection,
                        expectedRosettaAVXPolicy: disabled,
                        policy: pair.childPolicy,
                        expectedRequestProjection: pair.requestProjection
                    )
            ) { error in
                XCTAssertEqual(
                    error as? SteamCompatibilityLaunchProfileErrorV1,
                    .invalidReceipt(
                        "managed-wine-launch-environment-projection"
                    )
                )
            }
        }
    }

    func testNormalSteamStandardAndGameModeCommandSpecsCaptureAVXExactlyOnce()
        async throws
    {
        let fixture = try makeNormalSteamLaunchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for gameModePolicy in [
            SteamGameModeLaunchPolicy.standard,
            .experimentalRequiredHost
        ] {
            let snapshots = AVXSnapshotCounter(result: .managedDefault)
            let runner = makeAVXBoundaryRunner(
                snapshots: snapshots,
                applicationGroupContainer: fixture.root
            )
            let spec = try await runner.commandSpec(
                for: normalSteamLaunchAction(
                    fixture: fixture,
                    gameModePolicy: gameModePolicy
                )
            )
            XCTAssertEqual(
                spec.environment["WINELOADER"],
                fixture.runtimeExecutable.deletingLastPathComponent()
                    .appending(path: "wine.bin").path
            )
            let projection = try XCTUnwrap(
                SafeProcessRunner.managedWineLaunchEnvironmentProjection(
                    from: spec.environment
                )
            )

            XCTAssertEqual(snapshots.captureCount, 1)
            XCTAssertEqual(spec.managedWineRosettaAVXPolicy, .managedDefault)
            XCTAssertEqual(
                spec.environment[ManagedWineRosettaAVXPolicyV1.childEnvironmentKey],
                "1"
            )
            XCTAssertEqual(projection.rosettaAdvertiseAVX, "1")
            XCTAssertEqual(
                projection.transport,
                gameModePolicy == .standard ? "wine" : "game-mode-host"
            )
            XCTAssertNil(
                spec.environment[
                    Helldivers2ManagedWineChildPolicyContract.policyVersionKey
                ],
                "The normal Steam launch must not acquire a compatibility profile"
            )
        }
    }

    func testNormalSteamStandardAndGameModeRunsProjectCapturedAVXIntoResult()
        async throws
    {
        let cases: [(
            gameModePolicy: SteamGameModeLaunchPolicy,
            avxPolicy: ManagedWineRosettaAVXPolicyV1,
            expectedChildValue: String?,
            expectedTransport: String
        )] = [
            (
                .standard,
                try ManagedWineRosettaAVXPolicyV1.snapshot(hostOverride: "0"),
                nil,
                "wine"
            ),
            (
                .experimentalRequiredHost,
                try ManagedWineRosettaAVXPolicyV1.snapshot(hostOverride: "1"),
                "1",
                "game-mode-host"
            )
        ]

        for item in cases {
            let fixture = try makeNormalSteamLaunchFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let snapshots = AVXSnapshotCounter(result: item.avxPolicy)
            let runner = makeAVXBoundaryRunner(
                snapshots: snapshots,
                applicationGroupContainer: fixture.root
            )

            let result = try await runner.run(
                normalSteamLaunchAction(
                    fixture: fixture,
                    gameModePolicy: item.gameModePolicy
                )
            )

            XCTAssertEqual(snapshots.captureCount, 1)
            XCTAssertEqual(
                result.managedWineRosettaAVXPolicy,
                item.avxPolicy
            )
            // This result field projects the environment assigned by the
            // parent runner. It intentionally does not assert independent
            // observation inside Wine or the Game Mode host's child.
            XCTAssertEqual(
                result.managedWineLaunchEnvironmentProjection?
                    .rosettaAdvertiseAVX,
                item.expectedChildValue
            )
            XCTAssertEqual(
                result.managedWineLaunchEnvironmentProjection?.transport,
                item.expectedTransport
            )
            XCTAssertNil(
                result.managedWineLaunchEnvironmentProjection?.policyVersion,
                "Normal Steam result evidence must remain profile-independent"
            )
        }
    }

    func testInvalidAVXBlocksOnlyNewLaunchAdmissionNotRecoverySpecs()
        async throws
    {
        let fixture = try makeNormalSteamLaunchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshots = AVXSnapshotCounter(
            error: .invalidRosettaAVXHostOverride("invalid")
        )
        let runner = makeAVXBoundaryRunner(
            snapshots: snapshots,
            applicationGroupContainer: fixture.root
        )

        do {
            _ = try await runner.commandSpec(
                for: normalSteamLaunchAction(
                    fixture: fixture,
                    gameModePolicy: .standard
                )
            )
            XCTFail("Invalid ambient AVX must reject new launch admission")
        } catch let error as SafeProcessRunnerError {
            guard case .invalidRosettaAVXHostOverride("invalid") = error else {
                return XCTFail("Unexpected launch error: \(error)")
            }
        }
        XCTAssertEqual(snapshots.captureCount, 1)

        let shutdown = try await runner.commandSpec(
            for: .shutdownWinePrefix(
                runtimeExecutable: fixture.runtimeExecutable,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
        )
        let wait = try await runner.makeWinePrefixWaitCommandSpec(
            runtimeExecutable: fixture.runtimeExecutable,
            prefix: fixture.prefix,
            logDirectory: fixture.logs,
            actionName: "recoveryWait",
            logName: "recovery_wait",
            timeout: 1,
            allowsInvalidPrefixSynchronizationProfileForCleanup: true
        )
        let force = try await runner.makeWinePrefixSignalCommandSpec(
            runtimeExecutable: fixture.runtimeExecutable,
            prefix: fixture.prefix,
            logDirectory: fixture.logs,
            signal: SIGKILL,
            actionName: "forceRecovery",
            logName: "force_recovery",
            timeout: 1
        )

        XCTAssertEqual(snapshots.captureCount, 1)
        for spec in [shutdown, wait, force] {
            XCTAssertEqual(
                spec.environment[
                    ManagedWineRosettaAVXPolicyV1.childEnvironmentKey
                ],
                "1"
            )
            XCTAssertNil(spec.managedWineRosettaAVXPolicy)
        }
    }

    func testProviderRejectsEachUntruthfulFullRequestProjectionField() throws {
        let pair = try commandSpecAndPolicy(
            policy: .managedDefault,
            gameModePolicy: .standard
        )
        let mismatches = [
            ("FORGEPLAY_GAME_RENDERER_REQUESTED", "dxmt"),
            ("FORGEPLAY_NETWORK_PROFILE_REQUESTED", "wifi-identity"),
            ("FORGEPLAY_AUDIO_INPUT_MODE", "enabled"),
            ("FORGEPLAY_SYNCHRONIZATION_SELECTION", "msync"),
            ("FORGEPLAY_SYNCHRONIZATION_BACKEND", "msync")
        ]

        for (key, value) in mismatches {
            var environment = pair.spec.environment
            environment[key] = value
            let projection = SafeProcessRunner
                .managedWineLaunchEnvironmentProjection(from: environment)

            XCTAssertThrowsError(
                try SteamManagerCompatibilityLaunchRuntimeProviderV1
                    .requireLaunchEnvironmentProjection(
                        projection,
                        expectedRosettaAVXPolicy:
                            pair.spec.managedWineRosettaAVXPolicy,
                        policy: pair.childPolicy,
                        expectedRequestProjection: pair.requestProjection
                    )
            ) { error in
                XCTAssertEqual(
                    error as? SteamCompatibilityLaunchProfileErrorV1,
                    .invalidReceipt(
                        "managed-wine-launch-environment-projection"
                    ),
                    "Expected mismatch for \(key)"
                )
            }
        }
    }

    func testAppliedDigestGateRequiresExactManagedChildSynchronizationReadback()
        throws
    {
        XCTAssertNoThrow(
            try SteamManagerCompatibilityLaunchRuntimeProviderV1
                .requireManagedWineChildSynchronizationReadback(
                    ManagedWineChildSynchronizationReadback(
                        processIdentifier: 42,
                        selection: .automatic,
                        backend: .server
                    ),
                    processIdentifier: 42,
                    expectedSelection: .automatic
                )
        )

        let mismatches: [ManagedWineChildSynchronizationReadback?] = [
            nil,
            .init(
                processIdentifier: 41,
                selection: .automatic,
                backend: .server
            )
        ]
        for readback in mismatches {
            XCTAssertThrowsError(
                try SteamManagerCompatibilityLaunchRuntimeProviderV1
                    .requireManagedWineChildSynchronizationReadback(
                        readback,
                        processIdentifier: 42,
                        expectedSelection: .automatic
                    )
            ) { error in
                XCTAssertEqual(
                    error as? SteamCompatibilityLaunchProfileErrorV1,
                    .invalidReceipt(
                        "managed-wine-child-synchronization-readback"
                    )
                )
            }
        }
    }

    func testProfileErrorsExposeStableSanitizedTechnicalDescriptions() {
        let cases: [(SteamCompatibilityLaunchProfileErrorV1, String)] = [
            (
                .unsupportedContractVersion(9),
                "SteamCompatibilityLaunchProfileErrorV1 case=unsupportedContractVersion version=9"
            ),
            (
                .unsupportedRecipeSchemaVersion(7),
                "SteamCompatibilityLaunchProfileErrorV1 case=unsupportedRecipeSchemaVersion version=7"
            ),
            (
                .invalidRecipe("keyboard-preset"),
                "SteamCompatibilityLaunchProfileErrorV1 case=invalidRecipe reason=keyboard-preset"
            ),
            (
                .identityMismatch(expected: "expected", actual: "actual"),
                "SteamCompatibilityLaunchProfileErrorV1 case=identityMismatch expected=expected actual=actual"
            ),
            (
                .invalidPreference("generation"),
                "SteamCompatibilityLaunchProfileErrorV1 case=invalidPreference reason=generation"
            ),
            (
                .invalidCanonicalPayload("header"),
                "SteamCompatibilityLaunchProfileErrorV1 case=invalidCanonicalPayload reason=header"
            ),
            (
                .invalidManifestRootAuthorization("bookmark"),
                "SteamCompatibilityLaunchProfileErrorV1 case=invalidManifestRootAuthorization reason=bookmark"
            ),
            (
                .attemptedAutomaticPolicyRemoval,
                "SteamCompatibilityLaunchProfileErrorV1 case=attemptedAutomaticPolicyRemoval"
            ),
            (
                .unsupportedCapability(
                    category: "keyboard-preset\nprivate",
                    value: "windowsFriendly"
                ),
                "SteamCompatibilityLaunchProfileErrorV1 case=unsupportedCapability category=keyboard-preset%0Aprivate value=windowsFriendly"
            ),
            (
                .invalidReceipt("projection"),
                "SteamCompatibilityLaunchProfileErrorV1 case=invalidReceipt reason=projection"
            ),
            (
                .migrationRejected("schema"),
                "SteamCompatibilityLaunchProfileErrorV1 case=migrationRejected reason=schema"
            )
        ]

        for (error, expectedDescription) in cases {
            let erasedError: any Error = error
            XCTAssertTrue(erasedError is ForgePlayUserFacingLocalizedError)
            XCTAssertEqual(
                (error as ForgePlayTechnicalDescribingError)
                    .forgePlayTechnicalDescription,
                expectedDescription
            )
        }
    }

    @MainActor
    func testUserFacingBoundaryAcceptsProfileMarkerButNotOrdinaryLocalizedError() {
        let appState = AppState()
        appState.languageMode = .english
        let profileMessage = appState.localizedError(
            SteamCompatibilityLaunchProfileErrorV1
                .unsupportedCapability(
                    category: "keyboard-preset",
                    value: "windowsFriendly"
                )
        )
        let untrustedMessage = appState.localizedError(
            OrdinaryLocalizedError()
        )

        XCTAssertTrue(profileMessage.contains("keyboard-preset"))
        XCTAssertTrue(profileMessage.contains("windowsFriendly"))
        XCTAssertTrue(profileMessage.contains("supported option"))
        XCTAssertFalse(untrustedMessage.contains("untrusted-user-copy"))
    }

    private func assertUnsupportedKeyboardCategory(
        value: String,
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? SteamCompatibilityLaunchProfileErrorV1,
                .unsupportedCapability(
                    category: "recipe.keyboard-preset",
                    value: value
                ),
                file: file,
                line: line
            )
        }
    }

    private func commandSpecAndPolicy(
        policy: ManagedWineRosettaAVXPolicyV1,
        gameModePolicy: SteamGameModeLaunchPolicy
    ) throws -> (
        spec: CommandSpec,
        childPolicy: SteamManagedWineChildCompatibilityPolicy,
        requestProjection: SteamManagerCompatibilityLaunchProjectionV1
    ) {
        let root = URL(fileURLWithPath: "/Games/HELLDIVERS2", isDirectory: true)
            .standardizedFileURL
        let digestA = String(repeating: "a", count: 64)
        let digestB = String(repeating: "b", count: 64)
        let lineage = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let childPolicy = try SteamManagedWineChildCompatibilityPolicy(
            steamAppID: SteamManagedWineChildCompatibilityPolicy
                .helldivers2SteamAppID,
            canonicalGameRoot: root,
            canonicalGameRootIdentityDigest: digestA,
            anchoredLibraryPathIdentity: CompatibilityAnchoredPathIdentityV1(
                entries: [
                    .init(
                        path: root.path,
                        kind: .directory,
                        device: 1,
                        inode: 1
                    )
                ]
            ),
            manifestRootAuthorizationDigest: digestB,
            lineageNonce: lineage,
            heapZeroMemoryEnabled: true,
            excludesGameGuardRenderer: true
        )

        var environment = [
            "WINEPREFIX": "/prefix",
            "WINELOADER": "/runtime/wine64",
            Helldivers2ManagedWineChildPolicyContract.policyVersionKey:
                Helldivers2ManagedWineChildPolicyContract.policyVersion,
            Helldivers2ManagedWineChildPolicyContract.hostAuthorizationKey:
                Helldivers2ManagedWineChildPolicyContract.hostAuthorization,
            Helldivers2ManagedWineChildPolicyContract.steamAppIDKey:
                childPolicy.steamAppID,
            Helldivers2ManagedWineChildPolicyContract.canonicalRootKey:
                "Z:\\Games\\HELLDIVERS2",
            Helldivers2ManagedWineChildPolicyContract
                .canonicalRootIdentityTelemetryDigestKey: digestA,
            Helldivers2ManagedWineChildPolicyContract
                .manifestRootAuthorizationTelemetryDigestKey: digestB,
            Helldivers2ManagedWineChildPolicyContract.lineageNonceKey:
                lineage.uuidString.lowercased(),
            Helldivers2ManagedWineChildPolicyContract
                .heapZeroMemoryRequestedKey: "1",
            Helldivers2ManagedWineChildPolicyContract
                .gameGuardRendererExclusionRequestedKey: "1"
        ]
        let requestProjection = SteamManagerCompatibilityLaunchProjectionV1(
            rendererSelection: .d3dMetal,
            networkSelection: .standard,
            audioInputSelection: .disabled,
            synchronizationSelection: .automatic,
            videoMemorySelection: .automatic,
            videoMemorySizeMB:
                SteamVideoMemorySelection.automatic.resolvedSizeMB(),
            gameModePolicy: gameModePolicy,
            fpsCursorPolicy: .off,
            controllerPolicy: .automatic,
            keyboardMapping: .systemDefault,
            authorizedManifestRootDigest: digestB
        )
        environment["FORGEPLAY_GAME_RENDERER_REQUESTED"] =
            requestProjection.rendererSelection.rawValue
        environment["FORGEPLAY_NETWORK_PROFILE_REQUESTED"] =
            requestProjection.networkSelection.rawValue
        environment["FORGEPLAY_AUDIO_INPUT_MODE"] =
            requestProjection.audioInputSelection.rawValue
        environment["FORGEPLAY_SYNCHRONIZATION_SELECTION"] =
            requestProjection.synchronizationSelection.rawValue
        environment["FORGEPLAY_SYNCHRONIZATION_BACKEND"] =
            WineSynchronizationBackend.server.rawValue
        policy.apply(to: &environment)
        switch gameModePolicy {
        case .standard:
            environment = GameModeHostEnvironment.applyingStandardLaunch(
                to: environment
            )
        case .experimentalRequiredHost:
            environment[GameModeHostEnvironment.enabledKey] = "1"
        }

        var spec = CommandSpec(
            actionName: "launchSteam",
            executable: URL(fileURLWithPath: "/runtime/wine64"),
            arguments: [],
            environment: environment,
            workingDirectory: nil,
            stdoutLog: URL(fileURLWithPath: "/logs/stdout"),
            stderrLog: URL(fileURLWithPath: "/logs/stderr"),
            timeout: nil
        )
        spec.managedWineRosettaAVXPolicy = policy
        return (spec, childPolicy, requestProjection)
    }

    private struct NormalSteamLaunchFixture {
        let root: URL
        let runtimeExecutable: URL
        let prefix: URL
        let steamExecutable: URL
        let logs: URL
    }

    private final class AVXSnapshotCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let result: ManagedWineRosettaAVXPolicyV1?
        private let error: SafeProcessRunnerError?

        init(result: ManagedWineRosettaAVXPolicyV1) {
            self.result = result
            self.error = nil
        }

        init(error: SafeProcessRunnerError) {
            self.result = nil
            self.error = error
        }

        var captureCount: Int {
            lock.withLock { count }
        }

        func snapshot() throws -> ManagedWineRosettaAVXPolicyV1 {
            try lock.withLock {
                count += 1
                if let error { throw error }
                return result!
            }
        }
    }

    private func makeAVXBoundaryRunner(
        snapshots: AVXSnapshotCounter,
        applicationGroupContainer: URL
    ) -> SafeProcessRunner {
        let applicationGroupIdentifier =
            "group.com.forgeplay.tests.avx-boundary"
        return SafeProcessRunner(
            sandboxEnabled: false,
            managedWineProcessJournalEnabled: false,
            managedWineProcessEvidenceSandboxEnabled: false,
            gameModeHostApplicationGroupIdentifier:
                applicationGroupIdentifier,
            gameModeHostApplicationGroupContainerResolver: { identifier in
                guard identifier == applicationGroupIdentifier else {
                    return nil
                }
                return applicationGroupContainer
            },
            gameModeSteamChildSelectionResolver: {
                runtimeExecutable,
                prefix,
                evidenceLogURL,
                runIdentifier in
                let hostExecutable = runtimeExecutable
                    .deletingLastPathComponent()
                    .appending(path: "GameModeProcessHost")
                return GameModeSteamChildHostSelection(
                    host: GameModeHostCapability(
                        appURL: hostExecutable.deletingLastPathComponent()
                            .appending(path: "GameModeProcessHost.app"),
                        executableURL: hostExecutable,
                        bundleIdentifier:
                            "com.forgeplay.tests.game-mode-host",
                        executableSHA256: String(repeating: "b", count: 64),
                        supportsGameMode: true,
                        isRosettaRuntimeComponent: true
                    ),
                    runtimeNtdllURL: runtimeExecutable
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .appending(path: "lib/wine/x86_64-unix/ntdll.so"),
                    prefixExecutionLockURL: prefix.appending(
                        path: ".forgeplay-prefix-execution.lock"
                    ),
                    evidenceLogURL: evidenceLogURL,
                    runIdentifier: runIdentifier.lowercased()
                )
            },
            managedWineRuntimeFingerprintResolver: {
                _ in String(repeating: "a", count: 64)
            },
            managedWineRosettaAVXPolicySnapshotProvider: {
                try snapshots.snapshot()
            },
            runtimeLaunchObjectIdentityProvider: { _ in nil },
            windowsRuntimeValidator: { _, _ in }
        )
    }

    private func normalSteamLaunchAction(
        fixture: NormalSteamLaunchFixture,
        gameModePolicy: SteamGameModeLaunchPolicy
    ) -> RunnerAction {
        .launchSteam(
            runtimeExecutable: fixture.runtimeExecutable,
            prefix: fixture.prefix,
            steamExecutable: fixture.steamExecutable,
            steamArguments: [],
            graphicsBackend: .d3dMetal,
            compatibilitySelection: nil,
            gameModePolicy: gameModePolicy,
            logDirectory: fixture.logs
        )
    }

    private func makeNormalSteamLaunchFixture() throws
        -> NormalSteamLaunchFixture
    {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayNormalSteamAVX-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let runtimeRoot = root.appending(
            path: "ForgePlayRuntime",
            directoryHint: .isDirectory
        )
        let runtimeExecutable = runtimeRoot.appending(
            path: "wine/bin/wine"
        )
        let wineLoaderExecutable = runtimeExecutable
            .deletingLastPathComponent()
            .appending(path: "wine.bin")
        let prefix = root.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let steamExecutable = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steam.exe"
        )
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(
            path: "Frameworks/renderer/d3dmetal",
            directoryHint: .isDirectory
        )

        for directory in [
            runtimeExecutable.deletingLastPathComponent(),
            steamExecutable.deletingLastPathComponent(),
            logs
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try "#!/bin/sh\nexit 0\n".write(
            to: runtimeExecutable,
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/sh\nexit 0\n".write(
            to: wineLoaderExecutable,
            atomically: true,
            encoding: .utf8
        )
        for executable in [runtimeExecutable, wineLoaderExecutable] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        try Data().write(to: steamExecutable)
        try Data(
            #"{"synchronizationSelection":"automatic","synchronizationBackend":"server"}"#.utf8
        ).write(to: prefix.appending(path: "prefix.json"))
        try makeCompleteD3DMetalRenderer(at: renderer)
        return NormalSteamLaunchFixture(
            root: root,
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            steamExecutable: steamExecutable,
            logs: logs
        )
    }

    private func makeCompleteD3DMetalRenderer(at renderer: URL) throws {
        let relativePaths = [
            "external/libd3dshared.dylib",
            "external/D3DMetal.framework/D3DMetal",
            "external/D3DMetal.framework/Resources/Info.plist",
            "external/D3DMetal.framework/Resources/default.metallib",
            "external/D3DMetal.framework/Resources/libdxccontainer.dylib",
            "external/D3DMetal.framework/Resources/libdxcompiler.dylib",
            "external/D3DMetal.framework/Resources/libdxilconv.dylib",
            "external/D3DMetal.framework/Resources/libmetalirconverter.dylib",
            "wine/x86_64-unix/d3d10.so",
            "wine/x86_64-unix/d3d11.so",
            "wine/x86_64-unix/d3d12.so",
            "wine/x86_64-unix/dxgi.so",
            "wine/x86_64-unix/nvapi.so",
            "wine/x86_64-unix/nvapi64.so",
            "wine/x86_64-unix/nvngx-on-metalfx.so",
            "wine/x86_64-windows/d3d10.dll",
            "wine/x86_64-windows/d3d11.dll",
            "wine/x86_64-windows/d3d12.dll",
            "wine/x86_64-windows/dxgi.dll",
            "wine/x86_64-windows/nvapi.dll",
            "wine/x86_64-windows/nvapi64.dll",
            "wine/x86_64-windows/nvngx-on-metalfx.dll"
        ]
        let sharedUnixPaths = Set(
            D3DMetalRendererPayloadContract.sharedUnixModuleRelativePaths
        )
        for relativePath in relativePaths where
            !sharedUnixPaths.contains(relativePath)
        {
            let file = renderer.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("renderer fixture".utf8).write(to: file)
        }
        for relativePath in relativePaths where
            sharedUnixPaths.contains(relativePath)
        {
            let link = renderer.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                atPath: link.path,
                withDestinationPath:
                    D3DMetalRendererPayloadContract
                        .sharedUnixModuleLinkTarget
            )
        }
        let alias = renderer.appending(
            path: D3DMetalNVAPIAliasContract.windowsAliasRelativePath
        )
        try Data(
            contentsOf: renderer.appending(
                path: D3DMetalNVAPIAliasContract
                    .sourceWindowsModuleRelativePath
            )
        ).write(to: alias)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>D3DMetal</string>
        <key>CFBundleShortVersionString</key><string>4.0</string>
        <key>CFBundleVersion</key><string>4.0</string>
        </dict></plist>
        """.write(
            to: renderer.appending(
                path: "external/D3DMetal.framework/Resources/Info.plist"
            ),
            atomically: true,
            encoding: .utf8
        )
    }

    private func manifestAuthorization()
        async throws -> CompatibilityManifestRootAuthorizationTokenV1
    {
        let bookmark = try CompatibilityUnresolvedManifestRootBookmarkV1(
            securityScopedBookmark: Data("opaque-bookmark".utf8)
        )
        return try CompatibilityManifestRootAuthorizationTokenV1(
            providerID: "forgeplay.test-root-provider-v1",
            sourceBookmark: bookmark,
            pinnedVolumeIdentifier: Data("opaque-volume-id".utf8),
            pinnedFileIdentifier: Data("opaque-file-id".utf8)
        )
    }

    private struct OrdinaryLocalizedError: LocalizedError {
        var errorDescription: String? { "untrusted-user-copy" }
    }
}
