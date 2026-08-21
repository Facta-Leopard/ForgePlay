import Foundation
import XCTest
@testable import ForgePlay

final class SteamLaunchConfigurationProductAdapterTests: XCTestCase {
    func testV1ProductOptionCaseSetsRemainClosed() {
        XCTAssertEqual(
            SteamRendererPolicySelection.allCases.map(\.rawValue),
            ["d3dMetal", "d3dMetalNVIDIA", "dxmt", "d9vk", "vulkan"]
        )
        XCTAssertEqual(
            SteamNetworkCompatibilitySelection.allCases.map(\.rawValue),
            ["standard", "wifi-identity", "ethernet-identity"]
        )
        XCTAssertEqual(
            SteamAudioInputSelection.allCases.map(\.rawValue),
            ["disabled", "enabled"]
        )
        XCTAssertEqual(
            WineSynchronizationSelection.allCases.map(\.rawValue),
            ["automatic"]
        )
        XCTAssertEqual(
            SteamVideoMemorySelection.allCases.map(\.rawValue),
            ["automatic", "gb2", "gb4", "gb8", "gb12", "gb16"]
        )
    }

    func testEveryRendererMapsExactlyInBothDirections() throws {
        let cases: [(SteamRendererPolicySelection, String)] = [
            (.d3dMetal, "d3dMetal"),
            (.d3dMetalNVIDIA, "d3dMetalNVIDIA"),
            (.dxmt, "dxmt"),
            (.d9vk, "d9vk"),
            (.vulkan, "dxvk")
        ]

        for (renderer, identifier) in cases {
            let selection = makeSelection(renderer: renderer)
            let snapshot = try SteamLaunchConfigurationProductAdapter.standardSnapshot(
                selection: selection
            )
            XCTAssertEqual(snapshot.graphicsBackend.rawValue, identifier)
            XCTAssertEqual(
                try SteamLaunchConfigurationProductAdapter.productSelection(from: snapshot),
                selection
            )
        }
    }

    func testNetworkAudioVideoMemoryGameModeAndSynchronizationMapExactly() throws {
        for network in SteamNetworkCompatibilitySelection.allCases {
            let selection = makeSelection(network: network)
            let snapshot = try SteamLaunchConfigurationProductAdapter.standardSnapshot(
                selection: selection
            )
            XCTAssertEqual(snapshot.networkPolicy.rawValue, network.rawValue)
            XCTAssertEqual(
                try SteamLaunchConfigurationProductAdapter.productSelection(from: snapshot),
                selection
            )
        }

        for audioInput in SteamAudioInputSelection.allCases {
            let selection = makeSelection(audioInput: audioInput)
            let snapshot = try SteamLaunchConfigurationProductAdapter.standardSnapshot(
                selection: selection
            )
            XCTAssertEqual(snapshot.audioInputPolicy.rawValue, audioInput.rawValue)
            XCTAssertEqual(
                try SteamLaunchConfigurationProductAdapter.productSelection(from: snapshot),
                selection
            )
        }

        for videoMemory in SteamVideoMemorySelection.allCases {
            let selection = makeSelection(videoMemory: videoMemory)
            let snapshot = try SteamLaunchConfigurationProductAdapter.standardSnapshot(
                selection: selection
            )
            XCTAssertEqual(snapshot.videoMemoryPolicy.rawValue, videoMemory.rawValue)
            XCTAssertEqual(
                try SteamLaunchConfigurationProductAdapter.productSelection(from: snapshot),
                selection
            )
        }

        for gameModePolicy in [
            SteamGameModeLaunchPolicy.standard,
            .experimentalRequiredHost
        ] {
            let selection = makeSelection(gameModePolicy: gameModePolicy)
            let snapshot = try SteamLaunchConfigurationProductAdapter.standardSnapshot(
                selection: selection
            )
            XCTAssertEqual(
                snapshot.gameModeEnabled,
                gameModePolicy == .experimentalRequiredHost
            )
            XCTAssertEqual(
                try SteamLaunchConfigurationProductAdapter.productSelection(from: snapshot),
                selection
            )
        }

        let synchronizationSelection = makeSelection(synchronization: .automatic)
        let synchronizationSnapshot = try SteamLaunchConfigurationProductAdapter.standardSnapshot(
            selection: synchronizationSelection
        )
        XCTAssertEqual(synchronizationSnapshot.synchronizationPolicy.rawValue, "automatic")
        XCTAssertEqual(
            try SteamLaunchConfigurationProductAdapter.productSelection(
                from: synchronizationSnapshot
            ),
            synchronizationSelection
        )
    }

    func testNewStandardSnapshotMatchesDefaultsAndEnablesGameMode() throws {
        let snapshot = try SteamLaunchConfigurationProductAdapter.standardSnapshot(
            selection: makeSelection()
        )

        XCTAssertEqual(snapshot, .standardDefault)
        XCTAssertTrue(snapshot.gameModeEnabled)
        XCTAssertEqual(
            try SteamLaunchConfigurationProductAdapter.productSelection(from: snapshot)
                .gameModePolicy,
            .experimentalRequiredHost
        )
    }

    func testExplicitGameModeOffIsPreserved() throws {
        let selection = makeSelection(gameModePolicy: .standard)
        let snapshot = try SteamLaunchConfigurationProductAdapter.standardSnapshot(
            selection: selection
        )

        XCTAssertFalse(snapshot.gameModeEnabled)
        XCTAssertEqual(
            try SteamLaunchConfigurationProductAdapter.productSelection(from: snapshot),
            selection
        )
    }

    func testSnapshotProductSnapshotRoundTripIsStable() throws {
        let selection = makeSelection(
            renderer: .d3dMetalNVIDIA,
            network: .wifiIdentity,
            audioInput: .enabled,
            synchronization: .automatic,
            videoMemory: .gb12,
            gameModePolicy: .standard
        )
        let original = try SteamLaunchConfigurationProductAdapter.standardSnapshot(
            selection: selection
        )
        let resolved = try SteamLaunchConfigurationProductAdapter.productSelection(
            from: original
        )
        let rebuilt = try SteamLaunchConfigurationProductAdapter.standardSnapshot(
            selection: resolved,
            preserving: original
        )

        XCTAssertEqual(rebuilt, original)
        XCTAssertEqual(try rebuilt.canonicalDigest, try original.canonicalDigest)
    }

    func testUnsupportedModeAndUnknownLegacyIdentifiersFailClosedWhileInputPoliciesRoundTrip()
        throws {
        let compatibility = try SteamLaunchConfigurationSnapshot.compatibilityDefault(
            steamAppID: "553850",
            profileID: "helldivers-2",
            recipeRevision: "v1"
        )
        XCTAssertThrowsError(
            try SteamLaunchConfigurationProductAdapter.productSelection(from: compatibility)
        ) { error in
            XCTAssertEqual(
                error as? SteamLaunchConfigurationProductAdapterError,
                .unsupportedMode(.compatibility)
            )
        }

        assertUnsupportedOption(
            try SteamLaunchConfigurationSnapshot(
                identity: .standard,
                graphicsBackend: SteamGraphicsBackendIdentifier(rawValue: "vulkan")!
            ),
            category: SteamGraphicsBackendIdentifier.categoryName,
            value: "vulkan"
        )
        assertUnsupportedOption(
            try SteamLaunchConfigurationSnapshot(
                identity: .standard,
                graphicsBackend: SteamGraphicsBackendIdentifier(rawValue: "future-renderer")!
            ),
            category: SteamGraphicsBackendIdentifier.categoryName,
            value: "future-renderer"
        )
        assertUnsupportedOption(
            try SteamLaunchConfigurationSnapshot(
                identity: .standard,
                networkPolicy: SteamNetworkPolicyIdentifier(rawValue: "future-network")!
            ),
            category: SteamNetworkPolicyIdentifier.categoryName,
            value: "future-network"
        )
        assertUnsupportedOption(
            try SteamLaunchConfigurationSnapshot(
                identity: .standard,
                audioInputPolicy: SteamAudioInputPolicyIdentifier(rawValue: "future-audio")!
            ),
            category: SteamAudioInputPolicyIdentifier.categoryName,
            value: "future-audio"
        )
        assertUnsupportedOption(
            try SteamLaunchConfigurationSnapshot(
                identity: .standard,
                synchronizationPolicy: SteamSynchronizationPolicyIdentifier(rawValue: "msync")!
            ),
            category: SteamSynchronizationPolicyIdentifier.categoryName,
            value: "msync"
        )
        assertUnsupportedOption(
            try SteamLaunchConfigurationSnapshot(
                identity: .standard,
                videoMemoryPolicy: SteamVideoMemoryPolicyIdentifier(rawValue: "legacy")!
            ),
            category: SteamVideoMemoryPolicyIdentifier.categoryName,
            value: "legacy"
        )
        let supportedInputPolicies = try SteamLaunchConfigurationSnapshot(
            identity: .standard,
            fpsCursorPolicy: .fpsRelativeCaptureBeta,
            controllerPolicy: .forgePlayCompatibilityBridgeBeta,
            keyboardMapping: KeyboardMappingPreference(preset: .systemDefault)
        )
        let selection = try SteamLaunchConfigurationProductAdapter.productSelection(
            from: supportedInputPolicies
        )
        XCTAssertEqual(selection.fpsCursorPolicy, .fpsRelativeCaptureBeta)
        XCTAssertEqual(selection.controllerPolicy, .forgePlayCompatibilityBridgeBeta)
        XCTAssertEqual(selection.keyboardMapping.preset, .systemDefault)
        XCTAssertEqual(
            try SteamLaunchConfigurationProductAdapter.standardSnapshot(
                selection: selection
            ),
            supportedInputPolicies
        )
    }

    func testResolvedJournalContainsOnlyResolvedEvidence() throws {
        let snapshot = SteamLaunchConfigurationSnapshot.standardDefault
        let transactionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let journal = try SteamLaunchConfigurationProductAdapter.resolvedJournal(
            for: snapshot,
            transactionID: transactionID
        )
        let digest = try snapshot.canonicalDigest

        XCTAssertEqual(journal.transactionID, transactionID)
        XCTAssertEqual(journal.state, .resolved)
        XCTAssertEqual(journal.requestedDigest, digest)
        XCTAssertEqual(journal.resolvedDigest, digest)
        XCTAssertNil(journal.appliedDigest)
        XCTAssertNil(journal.capturedBaselineDigest)
        XCTAssertNil(journal.restoredBaselineDigest)
        XCTAssertEqual(journal.restorationState, .notRequired)
        XCTAssertEqual(journal.restoreAttemptCount, 0)
        XCTAssertNil(journal.failureCode)
    }

    func testResolvedJournalRejectsCompatibilityAndAcceptsSupportedInputPolicy() throws {
        let transactionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let compatibility = try SteamLaunchConfigurationSnapshot.compatibilityDefault(
            steamAppID: "553850",
            profileID: "helldivers-2",
            recipeRevision: "v1"
        )
        XCTAssertThrowsError(
            try SteamLaunchConfigurationProductAdapter.resolvedJournal(
                for: compatibility,
                transactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(
                error as? SteamLaunchConfigurationProductAdapterError,
                .unsupportedMode(.compatibility)
            )
        }

        let supportedInput = try SteamLaunchConfigurationSnapshot(
            identity: .standard,
            fpsCursorPolicy: .fpsRelativeCaptureBeta,
            controllerPolicy: .forgePlayCompatibilityBridgeBeta,
            keyboardMapping: KeyboardMappingPreference(preset: .systemDefault)
        )
        let journal = try SteamLaunchConfigurationProductAdapter.resolvedJournal(
            for: supportedInput,
            transactionID: transactionID
        )
        let digest = try supportedInput.canonicalDigest
        XCTAssertEqual(journal.state, .resolved)
        XCTAssertEqual(journal.requestedDigest, digest)
        XCTAssertEqual(journal.resolvedDigest, digest)
    }

    func testCompatibilityBaseIsRejectedWhenConstructingStandardDraft() throws {
        let compatibility = try SteamLaunchConfigurationSnapshot.compatibilityDefault(
            steamAppID: "553850",
            profileID: "helldivers-2",
            recipeRevision: "v1"
        )

        XCTAssertThrowsError(
            try SteamLaunchConfigurationProductAdapter.standardSnapshot(
                selection: makeSelection(),
                preserving: compatibility
            )
        ) { error in
            XCTAssertEqual(
                error as? SteamLaunchConfigurationProductAdapterError,
                .unsupportedMode(.compatibility)
            )
        }
    }

    private func makeSelection(
        renderer: SteamRendererPolicySelection = .d3dMetal,
        network: SteamNetworkCompatibilitySelection = .standard,
        audioInput: SteamAudioInputSelection = .disabled,
        synchronization: WineSynchronizationSelection = .automatic,
        videoMemory: SteamVideoMemorySelection = .automatic,
        gameModePolicy: SteamGameModeLaunchPolicy = .experimentalRequiredHost,
        fpsCursorPolicy: FPSCursorCapturePolicy = .off,
        controllerPolicy: ControllerCompatibilityPolicy = .automatic,
        keyboardMapping: KeyboardMappingPreference = .systemDefault
    ) -> SteamLaunchConfigurationProductSelection {
        SteamLaunchConfigurationProductSelection(
            rendererPolicySelection: renderer,
            networkSelection: network,
            audioInputSelection: audioInput,
            synchronizationSelection: synchronization,
            videoMemorySelection: videoMemory,
            gameModePolicy: gameModePolicy,
            fpsCursorPolicy: fpsCursorPolicy,
            controllerPolicy: controllerPolicy,
            keyboardMapping: keyboardMapping
        )
    }

    private func assertUnsupportedOption(
        _ snapshot: SteamLaunchConfigurationSnapshot,
        category: String,
        value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try SteamLaunchConfigurationProductAdapter.productSelection(from: snapshot),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? SteamLaunchConfigurationProductAdapterError,
                .unsupportedOption(category: category, value: value),
                file: file,
                line: line
            )
        }
    }
}
