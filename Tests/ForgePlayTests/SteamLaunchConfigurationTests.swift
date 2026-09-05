import Foundation
import XCTest
@testable import ForgePlay

final class SteamLaunchConfigurationTests: XCTestCase {
    private let digestA = String(repeating: "a", count: 64)
    private let digestB = String(repeating: "b", count: 64)

    @MainActor
    func testPostLaunchCleanupRetryPolicyRetriesIndefinitelyWithCappedBackoff() {
        XCTAssertEqual(
            (1...10).compactMap {
                SteamManagerCompatibilityLaunchRuntimeProviderV1
                    .PostLaunchCleanupRetryPolicy
                    .delayBeforeAttemptSeconds($0)
            },
            [0, 1, 2, 4, 8, 16, 32, 60, 60, 60]
        )
        XCTAssertNil(
            SteamManagerCompatibilityLaunchRuntimeProviderV1
                .PostLaunchCleanupRetryPolicy
                .delayBeforeAttemptSeconds(0)
        )
        XCTAssertEqual(
            SteamManagerCompatibilityLaunchRuntimeProviderV1
                .PostLaunchCleanupRetryPolicy
                .delayBeforeAttemptSeconds(10_000),
            60
        )
    }

    func testCompatibilityPrefixBindingRejectsDifferentPathAndSamePathReplacement()
        throws
    {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "ForgePlayPrefixBinding-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let prefixA = root.appending(path: "PrefixA", directoryHint: .isDirectory)
        let prefixB = root.appending(path: "PrefixB", directoryHint: .isDirectory)
        let movedPrefixA = root.appending(
            path: "PrefixA-original",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: prefixA, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: prefixB, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let binding = try SteamCompatibilityPrefixBinding(capturing: prefixA)
        XCTAssertEqual(
            try binding.validateCurrentPrefix(prefixA).path,
            prefixA.standardizedFileURL.resolvingSymlinksInPath().path
        )
        XCTAssertThrowsError(try binding.validateCurrentPrefix(prefixB)) { error in
            XCTAssertEqual(
                error as? SteamCompatibilityLaunchProfileErrorV1,
                .invalidReceipt("compatibility-prefix-path-binding-mismatch")
            )
        }

        try fileManager.moveItem(at: prefixA, to: movedPrefixA)
        try fileManager.createDirectory(at: prefixA, withIntermediateDirectories: false)
        XCTAssertThrowsError(try binding.validateCurrentPrefix(prefixA)) { error in
            XCTAssertEqual(
                error as? SteamCompatibilityLaunchProfileErrorV1,
                .invalidReceipt("compatibility-prefix-object-binding-mismatch")
            )
        }
    }

    @MainActor
    func testCompletionRendezvousCancelledAutomaticWaiterStillLetsTerminationJoinSameAttempt()
        async throws
    {
        let rendezvous = CompatibilityCompletionRendezvous<Int>()
        let operationGate = AsyncGate()
        var operationCount = 0
        let automaticAttempt = rendezvous.startOrJoin {
            operationCount += 1
            await operationGate.wait()
            return 42
        }
        XCTAssertTrue(automaticAttempt.didStart)

        let automaticWaiter = Task { @MainActor in
            try await rendezvous.wait(
                for: automaticAttempt.attempt,
                timeoutNanoseconds: 1_000_000_000
            )
        }
        await Task.yield()
        automaticWaiter.cancel()
        do {
            _ = try await automaticWaiter.value
            XCTFail("The cancelled automatic waiter unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: cancellation abandons only this waiter.
        }
        XCTAssertTrue(rendezvous.hasActiveAttempt)

        let terminationAttempt = rendezvous.startOrJoin {
            operationCount += 1
            return -1
        }
        XCTAssertFalse(terminationAttempt.didStart)
        operationGate.open()
        let terminationValue = try await rendezvous.wait(
            for: terminationAttempt.attempt,
            timeoutNanoseconds: 1_000_000_000
        )
        XCTAssertEqual(terminationValue, 42)
        XCTAssertEqual(operationCount, 1)
        XCTAssertTrue(rendezvous.finish(terminationAttempt.attempt))
        XCTAssertFalse(rendezvous.hasActiveAttempt)
    }

    @MainActor
    func testCompletionRendezvousTimeoutKeepsAttemptForTerminationJoin()
        async throws
    {
        let rendezvous = CompatibilityCompletionRendezvous<Int>()
        let operationGate = AsyncGate()
        var operationCount = 0
        let automaticAttempt = rendezvous.startOrJoin {
            operationCount += 1
            await operationGate.wait()
            return 84
        }

        do {
            _ = try await rendezvous.wait(
                for: automaticAttempt.attempt,
                timeoutNanoseconds: 1_000_000
            )
            XCTFail("The blocked automatic waiter unexpectedly completed")
        } catch let error as CompatibilityCompletionRendezvousError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertTrue(rendezvous.hasActiveAttempt)

        let terminationAttempt = rendezvous.startOrJoin {
            operationCount += 1
            return -1
        }
        XCTAssertFalse(terminationAttempt.didStart)
        operationGate.open()
        let terminationValue = try await rendezvous.wait(
            for: terminationAttempt.attempt,
            timeoutNanoseconds: 1_000_000_000
        )
        XCTAssertEqual(terminationValue, 84)
        XCTAssertEqual(operationCount, 1)
        XCTAssertTrue(rendezvous.finish(terminationAttempt.attempt))
        XCTAssertFalse(rendezvous.hasActiveAttempt)
    }

    @MainActor
    func testCompletionOwnershipPolicyEscalatesJoinedFailureOnceThenRearmsRecovery() {
        var policy = SteamManagerCompatibilityLaunchRuntimeProviderV1
            .CompletionOwnershipPolicyV1()
        XCTAssertFalse(
            policy.requiresRuntimeStopFirst(requestedByAttemptOwner: false)
        )

        policy.registerApplicationTerminationRequest()
        XCTAssertTrue(
            policy.requiresRuntimeStopFirst(requestedByAttemptOwner: false)
        )
        XCTAssertEqual(
            policy.failureDisposition(
                caller: .applicationTermination,
                attemptDidStart: false,
                didFinishAttempt: true,
                joinedTerminationFailureRetriesRemaining: 1
            ),
            .retryTerminationStopFirst(remainingRetries: 0)
        )
        XCTAssertEqual(
            policy.failureDisposition(
                caller: .applicationTermination,
                attemptDidStart: true,
                didFinishAttempt: true,
                joinedTerminationFailureRetriesRemaining: 0
            ),
            .rearmAutomaticRecovery
        )
        XCTAssertEqual(
            policy.failureDisposition(
                caller: .automatic,
                attemptDidStart: false,
                didFinishAttempt: false,
                joinedTerminationFailureRetriesRemaining: 0
            ),
            .keepRetainedForExistingRecovery
        )
    }

    @MainActor
    func testVerifiedCompletedReceiptRejectsEveryPreparationEvidenceMismatch()
        throws
    {
        let original = try makeProviderReceipt()
        let completed = try makeProviderReceipt(
            restoredBaselineDigest: String(repeating: "3", count: 64)
        )
        let verified = try SteamManagerCompatibilityLaunchRuntimeProviderV1
            .VerifiedCompletedReceipt(
                original: original,
                completed: completed
            )
        XCTAssertEqual(
            try verified.completedReceipt(matching: original),
            completed
        )

        let mismatchedReceipts = [
            try makeProviderReceipt(
                appliedStateDigest: String(repeating: "7", count: 64)
            ),
            try makeProviderReceipt(
                providerReadbackDigest: String(repeating: "8", count: 64)
            ),
            try makeProviderReceipt(
                componentAfterDigestOverride: String(repeating: "9", count: 64)
            )
        ]
        for receipt in mismatchedReceipts {
            XCTAssertThrowsError(
                try verified.completedReceipt(matching: receipt)
            ) { error in
                XCTAssertEqual(
                    error as? SteamCompatibilityLaunchProfileErrorV1,
                    .invalidReceipt(
                        "verified-completion-original-receipt-mismatch"
                    )
                )
            }
        }

        let mismatchedCompleted = try makeProviderReceipt(
            appliedStateDigest: String(repeating: "7", count: 64),
            restoredBaselineDigest: String(repeating: "3", count: 64)
        )
        XCTAssertThrowsError(
            try SteamManagerCompatibilityLaunchRuntimeProviderV1
                .VerifiedCompletedReceipt(
                    original: original,
                    completed: mismatchedCompleted
                )
        ) { error in
            XCTAssertEqual(
                error as? SteamCompatibilityLaunchProfileErrorV1,
                .invalidReceipt("verified-completion-binding-mismatch")
            )
        }
    }

    func testStandardAndCompatibilityDefaultsAreIndependentAndEnableGameMode() throws {
        let standard = SteamLaunchConfigurationSnapshot.standardDefault
        let compatibility = try SteamLaunchConfigurationSnapshot.compatibilityDefault(
            steamAppID: "553850",
            profileID: "helldivers-2",
            recipeRevision: "v1"
        )

        XCTAssertEqual(standard.identity.mode, .standard)
        XCTAssertEqual(standard.identity.configurationIdentity, "standard-default")
        XCTAssertTrue(standard.gameModeEnabled)
        XCTAssertTrue(compatibility.gameModeEnabled)
        XCTAssertEqual(standard.graphicsBackend, .d3dMetalNVIDIA)
        XCTAssertEqual(compatibility.graphicsBackend, .d3dMetal)
        XCTAssertEqual(standard.keyboardMapping.preset, .systemDefault)
        XCTAssertEqual(compatibility.keyboardMapping.preset, .systemDefault)
        XCTAssertNotEqual(try standard.canonicalDigest, try compatibility.canonicalDigest)
    }

    func testCompatibilityIdentityHasStableCompleteRecordID() throws {
        let identity = try SteamCompatibilityProfileIdentity(
            steamAppID: "553850",
            profileID: "helldivers-2",
            recipeRevision: "v1"
        )

        XCTAssertEqual(
            identity.deterministicRecordID,
            "compatibility-553850-05d2cabf037f6ee5b9bc618f85178d2283cdf8fcd7ce07ad20773c46ccbe323f"
        )
        XCTAssertEqual(
            identity.deterministicRecordID,
            try SteamCompatibilityProfileIdentity(
                steamAppID: "553850",
                profileID: "helldivers-2",
                recipeRevision: "v1"
            ).deterministicRecordID
        )
    }

    func testIdentityRejectsNormalizationAndBoundaryViolations() throws {
        XCTAssertThrowsError(
            try SteamCompatibilityProfileIdentity(
                steamAppID: "0553850",
                profileID: "helldivers-2",
                recipeRevision: "v1"
            )
        )
        XCTAssertThrowsError(
            try SteamCompatibilityProfileIdentity(
                steamAppID: "55a850",
                profileID: "helldivers-2",
                recipeRevision: "v1"
            )
        )
        XCTAssertThrowsError(
            try SteamCompatibilityProfileIdentity(
                steamAppID: String(repeating: "1", count: 21),
                profileID: "helldivers-2",
                recipeRevision: "v1"
            )
        )
        XCTAssertNoThrow(
            try SteamCompatibilityProfileIdentity(
                steamAppID: String(repeating: "1", count: 20),
                profileID: String(repeating: "a", count: 128),
                recipeRevision: String(repeating: "b", count: 128)
            )
        )
        XCTAssertThrowsError(
            try SteamCompatibilityProfileIdentity(
                steamAppID: "1",
                profileID: String(repeating: "a", count: 129),
                recipeRevision: "v1"
            )
        )
        XCTAssertThrowsError(
            try SteamCompatibilityProfileIdentity(
                steamAppID: "1",
                profileID: "contains/slash",
                recipeRevision: "v1"
            )
        )
    }

    func testIdentityCodableRejectsMissingAndUnexpectedFields() throws {
        let standardWithProfile = Data(
            #"{"mode":"standard","steamAppID":"1","profileID":"p","recipeRevision":"r"}"#.utf8
        )
        let compatibilityMissingRevision = Data(
            #"{"mode":"compatibility","steamAppID":"1","profileID":"p"}"#.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SteamLaunchConfigurationIdentity.self,
                from: standardWithProfile
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SteamLaunchConfigurationIdentity.self,
                from: compatibilityMissingRevision
            )
        )
    }

    func testOptionIdentifiersEnforceAlphabetAndPreserveUnknownValidValues() throws {
        XCTAssertNotNil(SteamGraphicsBackendIdentifier(rawValue: String(repeating: "a", count: 64)))
        XCTAssertNil(SteamGraphicsBackendIdentifier(rawValue: String(repeating: "a", count: 65)))
        XCTAssertNil(SteamGraphicsBackendIdentifier(rawValue: ""))
        XCTAssertNil(SteamGraphicsBackendIdentifier(rawValue: "future/backend"))
        XCTAssertNil(SteamGraphicsBackendIdentifier(rawValue: "미래"))

        let future = try XCTUnwrap(
            SteamGraphicsBackendIdentifier(rawValue: "future_backend-v2")
        )
        let encoded = try JSONEncoder().encode(future)
        XCTAssertEqual(
            try JSONDecoder().decode(SteamGraphicsBackendIdentifier.self, from: encoded),
            future
        )
    }

    func testKeyboardPreferenceRequiresBijectiveCustomPermutation() throws {
        let permutation = try ModifierKeyPermutation(
            command: .windows,
            option: .alt,
            control: .control
        )
        let preference = try KeyboardMappingPreference(
            preset: .custom,
            customPermutation: permutation
        )

        XCTAssertEqual(preference.customPermutation, permutation)
        XCTAssertThrowsError(
            try ModifierKeyPermutation(command: .control, option: .control, control: .windows)
        )
        XCTAssertThrowsError(try KeyboardMappingPreference(preset: .custom))
        XCTAssertThrowsError(
            try KeyboardMappingPreference(
                preset: .windowsFriendly,
                customPermutation: permutation
            )
        )
    }

    func testCanonicalPayloadRoundTripsAndUsesExactFieldOrder() throws {
        let snapshot = try SteamLaunchConfigurationSnapshot.compatibilityDefault(
            steamAppID: "553850",
            profileID: "helldivers-2",
            recipeRevision: "v1"
        )
        let payload = try snapshot.canonicalPayload()
        let text = try XCTUnwrap(String(data: payload, encoding: .utf8))

        XCTAssertTrue(text.hasPrefix("forgeplay-steam-launch-configuration-v5\n"))
        XCTAssertTrue(text.contains("schemaVersion=1:5\nmode=13:compatibility\n"))
        XCTAssertTrue(text.contains("frameGenerationEnabled=1:0\n"))
        XCTAssertTrue(text.contains("frameGenerationTargetFPS=3:120\n"))
        XCTAssertTrue(text.contains("frameCheckEnabled=1:0\n"))
        XCTAssertEqual(try SteamLaunchConfigurationSnapshot(canonicalPayload: payload), snapshot)
        XCTAssertEqual(
            try SteamLaunchConfigurationSnapshot(canonicalPayload: payload).canonicalPayload(),
            payload
        )
    }

    func testStandardFrameGenerationAndFrameCheckRoundTrip() throws {
        let snapshot = try SteamLaunchConfigurationSnapshot(
            identity: .standard,
            graphicsBackend: .d3dMetalNVIDIA,
            frameGenerationConfiguration: FrameGenerationConfiguration(
                isEnabled: true,
                targetFrameRate: .fps120,
                isFrameCheckEnabled: true
            )
        )

        let payload = try snapshot.canonicalPayload()
        let restored = try SteamLaunchConfigurationSnapshot(
            canonicalPayload: payload
        )
        XCTAssertEqual(restored, snapshot)
        XCTAssertTrue(restored.frameGenerationConfiguration.isEnabled)
        XCTAssertTrue(
            restored.frameGenerationConfiguration.isFrameCheckEnabled
        )
        XCTAssertEqual(
            restored.frameGenerationConfiguration.targetFrameRate,
            .fps120
        )

        let explicitFrameCheckOffSnapshot = try SteamLaunchConfigurationSnapshot(
            identity: .standard,
            graphicsBackend: .d3dMetalNVIDIA,
            frameGenerationConfiguration: FrameGenerationConfiguration(
                isEnabled: true,
                targetFrameRate: .fps120,
                isFrameCheckEnabled: false
            )
        )
        let explicitFrameCheckOffRestored = try SteamLaunchConfigurationSnapshot(
            canonicalPayload: explicitFrameCheckOffSnapshot.canonicalPayload()
        )
        XCTAssertTrue(
            explicitFrameCheckOffRestored.frameGenerationConfiguration.isEnabled
        )
        XCTAssertFalse(
            explicitFrameCheckOffRestored.frameGenerationConfiguration
                .isFrameCheckEnabled
        )
    }

    func testCanonicalPayloadRejectsStructuralAndEncodingMutations() throws {
        let snapshot = try SteamLaunchConfigurationSnapshot.compatibilityDefault(
            steamAppID: "553850",
            profileID: "helldivers-2",
            recipeRevision: "v1"
        )
        let payload = try snapshot.canonicalPayload()
        let text = try XCTUnwrap(String(data: payload, encoding: .utf8))
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var trailing = payload
        trailing.append(0)
        XCTAssertThrowsError(try SteamLaunchConfigurationSnapshot(canonicalPayload: trailing))

        let nonminimal = try replacing(
            in: payload,
            target: Data("schemaVersion=1:5".utf8),
            replacement: Data("schemaVersion=01:5".utf8)
        )
        XCTAssertThrowsError(try SteamLaunchConfigurationSnapshot(canonicalPayload: nonminimal))

        lines.swapAt(1, 2)
        let reordered = Data(lines.joined(separator: "\n").utf8)
        XCTAssertThrowsError(try SteamLaunchConfigurationSnapshot(canonicalPayload: reordered))

        let missing = Data(text.split(separator: "\n").dropLast().joined(separator: "\n").utf8)
        XCTAssertThrowsError(try SteamLaunchConfigurationSnapshot(canonicalPayload: missing))

        let unknown = try replacing(
            in: payload,
            target: Data("networkPolicy=".utf8),
            replacement: Data("unknownPolicy=".utf8)
        )
        XCTAssertThrowsError(try SteamLaunchConfigurationSnapshot(canonicalPayload: unknown))

        var duplicate = payload
        duplicate.append(contentsOf: "customControlRole=1:-\n".utf8)
        XCTAssertThrowsError(try SteamLaunchConfigurationSnapshot(canonicalPayload: duplicate))

        var invalidUTF8 = payload
        let profileID = "helldivers-2"
        let profileFieldPrefix = Data("profileID=\(profileID.utf8.count):".utf8)
        let profileFieldPrefixRange = try XCTUnwrap(
            invalidUTF8.range(of: profileFieldPrefix)
        )
        invalidUTF8[profileFieldPrefixRange.upperBound] = 0xff
        XCTAssertThrowsError(try SteamLaunchConfigurationSnapshot(canonicalPayload: invalidUTF8))
    }

    func testLegacyCanonicalPayloadMigratesWithFrameGenerationOff() throws {
        let legacyPayload = canonicalPayload(
            header: "forgeplay-steam-launch-configuration-v1",
            fields: [
                ("schemaVersion", "1"),
                ("mode", SteamLaunchMode.standard.rawValue),
                (
                    "configurationIdentity",
                    SteamLaunchConfigurationIdentity.standard
                        .configurationIdentity
                ),
                ("steamAppID", ""),
                ("profileID", ""),
                ("recipeRevision", ""),
                ("graphicsBackend", SteamGraphicsBackendIdentifier.d3dMetal.rawValue),
                ("networkPolicy", SteamNetworkPolicyIdentifier.standard.rawValue),
                ("audioInputPolicy", SteamAudioInputPolicyIdentifier.disabled.rawValue),
                (
                    "synchronizationPolicy",
                    SteamSynchronizationPolicyIdentifier.automatic.rawValue
                ),
                ("videoMemoryPolicy", SteamVideoMemoryPolicyIdentifier.automatic.rawValue),
                ("gameModeEnabled", "1"),
                ("fpsCursorPolicy", FPSCursorCapturePolicy.off.rawValue),
                ("controllerPolicy", ControllerCompatibilityPolicy.automatic.rawValue),
                ("keyboardPreset", KeyboardMappingPreset.systemDefault.rawValue),
                ("hasCustomPermutation", "0"),
                ("customCommandRole", "-"),
                ("customOptionRole", "-"),
                ("customControlRole", "-")
            ]
        )

        let migrated = try SteamLaunchConfigurationSnapshot(
            canonicalPayload: legacyPayload
        )
        XCTAssertEqual(
            migrated.schemaVersion,
            SteamLaunchConfigurationSnapshot.currentSchemaVersion
        )
        XCTAssertEqual(migrated.frameGenerationConfiguration, .off)
        XCTAssertTrue(
            try migrated.canonicalPayload().starts(
                with: Data("forgeplay-steam-launch-configuration-v5\n".utf8)
            )
        )
    }

    func testDeployedFrameGenerationSchemasAndInterimSchema2MigrateToSchema5()
        throws
    {
        let commonPrefix: [(String, String)] = [
            ("mode", SteamLaunchMode.standard.rawValue),
            (
                "configurationIdentity",
                SteamLaunchConfigurationIdentity.standard.configurationIdentity
            ),
            ("steamAppID", ""),
            ("profileID", ""),
            ("recipeRevision", ""),
            ("graphicsBackend", "d3dMetalNVIDIA")
        ]
        let commonSuffix: [(String, String)] = [
            ("networkPolicy", "standard"),
            ("audioInputPolicy", "disabled"),
            ("synchronizationPolicy", "automatic"),
            ("videoMemoryPolicy", "automatic"),
            ("gameModeEnabled", "1"),
            ("fpsCursorPolicy", "off"),
            ("controllerPolicy", "automatic"),
            ("keyboardPreset", "systemDefault"),
            ("hasCustomPermutation", "0"),
            ("customCommandRole", "-"),
            ("customOptionRole", "-"),
            ("customControlRole", "-")
        ]
        let deployedV2 = canonicalPayload(
            header: "forgeplay-steam-launch-configuration-v2",
            fields: [("schemaVersion", "2")] + commonPrefix + [
                ("d3dMetalFrameGenerationMode", "off"),
                ("d3dMetalNVIDIAFrameGenerationMode", "midpoint"),
                ("dxmtFrameGenerationMode", "off"),
                ("d9vkFrameGenerationMode", "off"),
                ("vulkanFrameGenerationMode", "off")
            ] + commonSuffix
        )
        let deployedV3 = canonicalPayload(
            header: "forgeplay-steam-launch-configuration-v3",
            fields: [("schemaVersion", "3")] + commonPrefix + [
                ("frameGenerationEnabled", "1")
            ] + commonSuffix
        )
        let deployedV4 = canonicalPayload(
            header: "forgeplay-steam-launch-configuration-v4",
            fields: [("schemaVersion", "4")] + commonPrefix + [
                ("frameGenerationTargetFPS", "120")
            ] + commonSuffix
        )
        let interimV2 = canonicalPayload(
            header: "forgeplay-steam-launch-configuration-v2",
            fields: [("schemaVersion", "2")] + commonPrefix + [
                ("networkPolicy", "standard"),
                ("audioInputPolicy", "disabled"),
                ("synchronizationPolicy", "automatic"),
                ("videoMemoryPolicy", "automatic"),
                ("frameGenerationEnabled", "1"),
                ("frameGenerationTargetFPS", "120"),
                ("frameCheckEnabled", "0"),
                ("gameModeEnabled", "1"),
                ("fpsCursorPolicy", "off"),
                ("controllerPolicy", "automatic"),
                ("keyboardPreset", "systemDefault"),
                ("hasCustomPermutation", "0"),
                ("customCommandRole", "-"),
                ("customOptionRole", "-"),
                ("customControlRole", "-")
            ]
        )

        for payload in [deployedV2, deployedV3, deployedV4] {
            let migrated = try SteamLaunchConfigurationSnapshot(
                canonicalPayload: payload
            )
            XCTAssertEqual(migrated.schemaVersion, 5)
            XCTAssertTrue(migrated.frameGenerationConfiguration.isEnabled)
            XCTAssertTrue(
                migrated.frameGenerationConfiguration.isFrameCheckEnabled
            )
            XCTAssertTrue(
                try migrated.canonicalPayload().starts(
                    with: Data(
                        "forgeplay-steam-launch-configuration-v5\n".utf8
                    )
                )
            )
        }

        let interimMigrated = try SteamLaunchConfigurationSnapshot(
            canonicalPayload: interimV2
        )
        XCTAssertTrue(interimMigrated.frameGenerationConfiguration.isEnabled)
        XCTAssertFalse(
            interimMigrated.frameGenerationConfiguration.isFrameCheckEnabled
        )

        let invalidRendererMode = try replacing(
            in: deployedV2,
            target: Data(
                "d3dMetalNVIDIAFrameGenerationMode=8:midpoint".utf8
            ),
            replacement: Data(
                "d3dMetalNVIDIAFrameGenerationMode=8:garbage!".utf8
            )
        )
        XCTAssertThrowsError(
            try SteamLaunchConfigurationSnapshot(
                canonicalPayload: invalidRendererMode
            )
        )
        let invalidTarget = try replacing(
            in: deployedV4,
            target: Data("frameGenerationTargetFPS=3:120".utf8),
            replacement: Data("frameGenerationTargetFPS=3:999".utf8)
        )
        XCTAssertThrowsError(
            try SteamLaunchConfigurationSnapshot(
                canonicalPayload: invalidTarget
            )
        )
    }

    func testUnsupportedSchemaVersionIsRejectedWithoutFallback() {
        XCTAssertThrowsError(
            try SteamLaunchConfigurationSnapshot(
                schemaVersion: SteamLaunchConfigurationSnapshot.currentSchemaVersion + 1,
                identity: .standard
            )
        )
    }

    func testTransactionTransitionsAndRestorationRetryMaintainInvariants() throws {
        var journal = try SteamLaunchConfigurationTransactionJournal(requestedDigest: digestA)
        XCTAssertEqual(journal.state, .requested)
        XCTAssertEqual(journal.restorationState, .notRequired)

        try journal.resolve(resolvedDigest: digestA)
        try journal.apply(appliedDigest: digestA, capturedBaselineDigest: digestB)
        try journal.markRestoreFailed(failureCode: "restore-attempt-1")
        try journal.markRestoreFailed(failureCode: "restore-attempt-2")
        let beforeRejectedThirdAttempt = journal
        XCTAssertThrowsError(try journal.markRestoreFailed(failureCode: "restore-attempt-3"))
        XCTAssertEqual(journal, beforeRejectedThirdAttempt)

        try journal.markRestored(restoredBaselineDigest: digestB)
        XCTAssertEqual(journal.state, .restored)
        XCTAssertEqual(journal.restorationState, .succeeded)
        XCTAssertEqual(journal.restoreAttemptCount, 2)
        XCTAssertNil(journal.failureCode)
        XCTAssertNoThrow(try journal.validate())

        let encoded = try JSONEncoder().encode(journal)
        XCTAssertEqual(
            try JSONDecoder().decode(
                SteamLaunchConfigurationTransactionJournal.self,
                from: encoded
            ),
            journal
        )
    }

    func testTransactionRejectsMalformedAndSkippedTransitionsAtomically() throws {
        let zeroID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        XCTAssertThrowsError(
            try SteamLaunchConfigurationTransactionJournal(
                transactionID: zeroID,
                requestedDigest: digestA
            )
        )
        XCTAssertThrowsError(
            try SteamLaunchConfigurationTransactionJournal(
                requestedDigest: "A" + String(digestA.dropFirst())
            )
        )

        var requested = try SteamLaunchConfigurationTransactionJournal(requestedDigest: digestA)
        let original = requested
        XCTAssertThrowsError(
            try requested.apply(appliedDigest: digestA, capturedBaselineDigest: digestB)
        )
        XCTAssertEqual(requested, original)

        try requested.resolve(resolvedDigest: digestA)
        let resolved = requested
        XCTAssertThrowsError(
            try requested.apply(appliedDigest: digestB, capturedBaselineDigest: digestA)
        )
        XCTAssertEqual(requested, resolved)

        try requested.apply(appliedDigest: digestA, capturedBaselineDigest: digestB)
        let applied = requested
        XCTAssertThrowsError(try requested.markRestored(restoredBaselineDigest: digestA))
        XCTAssertEqual(requested, applied)
        XCTAssertThrowsError(try requested.markRestoreFailed(failureCode: "bad code"))
        XCTAssertEqual(requested, applied)
    }

    private func replacing(in data: Data, target: Data, replacement: Data) throws -> Data {
        let range = try XCTUnwrap(data.range(of: target))
        var result = data
        result.replaceSubrange(range, with: replacement)
        return result
    }

    private func canonicalPayload(
        header: String,
        fields: [(String, String)]
    ) -> Data {
        var data = Data((header + "\n").utf8)
        for (name, value) in fields {
            data.append(contentsOf: "\(name)=\(value.utf8.count):".utf8)
            data.append(contentsOf: value.utf8)
            data.append(10)
        }
        return data
    }

    private func makeProviderReceipt(
        appliedStateDigest: String = String(repeating: "4", count: 64),
        providerReadbackDigest: String = String(repeating: "5", count: 64),
        componentAfterDigestOverride: String? = nil,
        restoredBaselineDigest: String? = nil
    ) throws -> CompatibilityLaunchApplicationReceiptV1 {
        let beforeDigest = String(repeating: "1", count: 64)
        let afterDigest = String(repeating: "2", count: 64)
        let componentIDs = CompatibilityRuntimeApplicationEvidenceV1
            .expectedMutationComponentIDs.sorted()
        let componentEvidence = componentIDs.enumerated().map { index, componentID in
            let effectiveAfter = index == 0
                ? componentAfterDigestOverride ?? afterDigest
                : afterDigest
            return CompatibilityRuntimeComponentMutationEvidenceV1(
                componentID: componentID,
                beforeDigest: beforeDigest,
                afterDigest: effectiveAfter,
                readbackDigest: effectiveAfter
            )
        }
        let requestDigest = String(repeating: "6", count: 64)
        return try CompatibilityLaunchApplicationReceiptV1(
            providerID: "forgeplay.test-full-receipt-binding-v1",
            receiptID: "full-receipt-binding",
            requestDigest: requestDigest,
            transactionID: UUID(uuidString: "12345678-1234-1234-1234-1234567890ab")!,
            evidence: CompatibilityRuntimeApplicationEvidenceV1(
                appliedRequestDigest: requestDigest,
                capturedBaselineDigest: String(repeating: "3", count: 64),
                appliedStateDigest: appliedStateDigest,
                providerReadbackDigest: providerReadbackDigest,
                componentMutationEvidence: componentEvidence,
                restoredBaselineDigest: restoredBaselineDigest
            )
        )
    }

    @MainActor
    private final class AsyncGate {
        private var isOpen = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let pending = continuations
            continuations.removeAll(keepingCapacity: false)
            pending.forEach { $0.resume() }
        }
    }
}
