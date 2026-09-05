import Foundation
import XCTest
@testable import ForgePlay

final class D3DMetalFrameGenerationContractTests: XCTestCase {
    func testReleaseSelectionAndLaunchPanelOrderingMatchProductContract() {
        XCTAssertEqual(
            FrameGenerationPolicy.visibleTargetFrameRates,
            [.fps120, .fps144, .fps240]
        )
        XCTAssertEqual(
            FrameGenerationPolicy.selectableTargetFrameRates,
            [.fps120]
        )
        XCTAssertEqual(
            SteamRendererPolicySelection.currentReleaseSelectableCases,
            [.d3dMetalNVIDIA, .dxmt, .d9vk]
        )
        XCTAssertEqual(
            SteamRendererPolicySelection.d3dMetal.normalizedForCurrentRelease,
            .d3dMetalNVIDIA
        )
        XCTAssertEqual(
            SteamRendererPolicySelection.vulkan.normalizedForCurrentRelease,
            .d3dMetalNVIDIA
        )
        XCTAssertEqual(
            SteamRendererPolicySelection.dxmt.normalizedForCurrentRelease,
            .dxmt
        )
        XCTAssertEqual(
            SteamRendererPolicySelection.d9vk.normalizedForCurrentRelease,
            .d9vk
        )
        XCTAssertTrue(
            SteamRendererPolicySelection.d3dMetalNVIDIA
                .supportsD3DMetalFrameGeneration
        )
        XCTAssertFalse(
            SteamRendererPolicySelection.d3dMetal
                .supportsD3DMetalFrameGeneration
        )
        XCTAssertFalse(
            SteamRendererPolicySelection.dxmt.supportsD3DMetalFrameGeneration
        )
        XCTAssertFalse(
            SteamRendererPolicySelection.d9vk.supportsD3DMetalFrameGeneration
        )
        XCTAssertEqual(
            StandardSteamLaunchPanelSection.ordered,
            [
                .renderer,
                .frameGeneration,
                .gameMode,
                .compatibility,
                .keyboard,
                .controller,
                .configurationState
            ]
        )
    }

    func testFrameGenerationConfigurationEnforcesReleaseAvailability() throws {
        var invalidConfiguration = FrameGenerationConfiguration(
            isEnabled: false,
            targetFrameRate: .fps120,
            isFrameCheckEnabled: true
        )
        XCTAssertThrowsError(
            try invalidConfiguration.validate(isSupportedRenderer: true)
        ) { error in
            XCTAssertEqual(
                error as? FrameGenerationConfigurationError,
                .frameCheckRequiresFrameGeneration
            )
        }
        invalidConfiguration.setEnabled(false)
        XCTAssertFalse(invalidConfiguration.isFrameCheckEnabled)

        var dormantFutureTarget = FrameGenerationConfiguration(
            isEnabled: false,
            targetFrameRate: .fps240,
            isFrameCheckEnabled: false
        )
        XCTAssertNoThrow(
            try dormantFutureTarget.validate(isSupportedRenderer: false)
        )
        dormantFutureTarget.setEnabled(true)
        XCTAssertEqual(dormantFutureTarget.targetFrameRate, .fps120)
        XCTAssertNoThrow(
            try dormantFutureTarget.validate(isSupportedRenderer: true)
        )
    }

    func testFrameCheckDefaultsOnOnlyForOffToOnUserTransition() throws {
        var newDraft = FrameGenerationConfiguration.off
        newDraft.setEnabled(true)
        XCTAssertTrue(newDraft.isEnabled)
        XCTAssertTrue(newDraft.isFrameCheckEnabled)
        XCTAssertNoThrow(
            try newDraft.validate(isSupportedRenderer: true)
        )

        var explicitlySavedFrameCheckOff = FrameGenerationConfiguration(
            isEnabled: true,
            targetFrameRate: .fps120,
            isFrameCheckEnabled: false
        )
        explicitlySavedFrameCheckOff.setEnabled(true)
        XCTAssertTrue(explicitlySavedFrameCheckOff.isEnabled)
        XCTAssertFalse(explicitlySavedFrameCheckOff.isFrameCheckEnabled)

        explicitlySavedFrameCheckOff.setEnabled(false)
        explicitlySavedFrameCheckOff.setEnabled(true)
        XCTAssertTrue(explicitlySavedFrameCheckOff.isFrameCheckEnabled)
    }

    func testReleaseTelemetryParserAcceptsMonitoringActiveAndPreProxyErrorRecords() throws {
        let records = [
            record(
                processID: 4210,
                state: "monitoring",
                target: 120,
                sourcePresentSeen: 120,
                captureReady: 0,
                generatedSubmitted: 0,
                generatedCompleted: 0,
                generatedPresented: 0,
                midpoint: 0,
                outputActive: 0,
                displayUpdates: 0,
                cadence: 0,
                reason: "monitoring-source",
                extended: true,
                maximumPresentationsInFlight: 3,
                sourceCadence: 100,
                originalCadence: 100,
                generatedCadence: 0,
                outputSourceRatio: 0
            ),
            record(
                processID: 4210,
                state: "priming",
                target: 120,
                sourcePresentSeen: 8,
                captureReady: 8,
                generatedSubmitted: 1,
                generatedCompleted: 1,
                generatedPresented: 0,
                midpoint: 0,
                outputActive: 0,
                displayUpdates: 16,
                cadence: 0,
                reason: "generated-completed",
                extended: true,
                currentPresented: 0,
                midpointAdmitted: 1,
                presentationsInFlight: 1
            ),
            record(
                processID: 4210,
                state: "active",
                target: 120,
                sourcePresentSeen: 12,
                captureReady: 12,
                generatedSubmitted: 3,
                generatedCompleted: 3,
                generatedPresented: 2,
                midpoint: 2,
                outputActive: 1,
                displayUpdates: 32,
                cadence: 119.75,
                reason: "midpoint-presented",
                extended: true,
                currentPresented: 2,
                midpointAdmitted: 2,
                presentationsInFlight: 2,
                maximumPresentationsInFlight: 3,
                effectiveSlotMilliseconds: 8.333,
                sourceCadence: 90,
                originalCadence: 90,
                generatedCadence: 30,
                outputSourceRatio: 1.25,
                outputPolicy: "generated-burst",
                captureInFlight: 3,
                maximumCaptureInFlight: 3,
                demandProbePhase: "generated-output"
            ),
            record(
                processID: 5110,
                state: "error",
                target: 0,
                sourcePresentSeen: 0,
                captureReady: 0,
                generatedSubmitted: 0,
                generatedCompleted: 0,
                generatedPresented: 0,
                midpoint: 0,
                outputActive: 0,
                displayUpdates: 0,
                cadence: 0,
                reason: "invalid-target-hz"
            )
        ]
        let observations = SteamProcessCreationObservationLog
            .parseD3DMetalFrameGenerationObservations(
                Data((records.joined(separator: "\n") + "\n").utf8)
            )

        XCTAssertEqual(observations.count, 4)
        let monitoring = try XCTUnwrap(observations.first)
        let priming = try XCTUnwrap(observations.dropFirst().first)
        let active = try XCTUnwrap(observations.dropFirst(2).first)
        let error = try XCTUnwrap(observations.last)
        XCTAssertEqual(monitoring.state, .monitoring)
        XCTAssertEqual(monitoring.sourceCadenceHz, 100)
        XCTAssertEqual(monitoring.originalCadenceHz, 100)
        XCTAssertEqual(monitoring.generatedCadenceHz, 0)
        XCTAssertEqual(monitoring.captureReady, 0)
        XCTAssertFalse(monitoring.outputActive)
        XCTAssertFalse(monitoring.meetsActivationContract(after: monitoring))
        XCTAssertFalse(priming.meetsActivationContract(after: priming))
        XCTAssertFalse(active.meetsActivationContract(after: priming))
        XCTAssertEqual(active.generatedPresented, 2)
        XCTAssertEqual(active.midpointPresented, 2)
        XCTAssertEqual(active.displayUpdates, 32)
        XCTAssertEqual(active.cadenceHz, 119.75, accuracy: 0.001)
        XCTAssertEqual(active.currentPresented, 2)
        XCTAssertEqual(active.midpointAdmitted, 2)
        XCTAssertEqual(active.presentationsInFlight, 2)
        XCTAssertEqual(active.maximumPresentationsInFlight, 3)
        XCTAssertEqual(
            try XCTUnwrap(active.effectiveDisplaySlotMilliseconds),
            8.333,
            accuracy: 0.001
        )
        XCTAssertEqual(active.sourceCadenceHz, 90)
        XCTAssertEqual(active.originalCadenceHz, 90)
        XCTAssertEqual(active.generatedCadenceHz, 30)
        XCTAssertEqual(active.outputSourceRatio, 1.25)
        XCTAssertEqual(active.currentSourceRatio, 1)
        XCTAssertEqual(active.admissionScale, 1)
        XCTAssertEqual(active.rawDebt, 0)
        XCTAssertEqual(active.outputPolicy, "generated-burst")
        XCTAssertEqual(active.presentationStallChecks, 0)
        XCTAssertEqual(active.sourceDemandCredit, 0.5)
        XCTAssertEqual(active.readyBundleDepth, 1)
        XCTAssertEqual(active.maximumReadyBundleDepth, 2)
        XCTAssertEqual(active.currentQueueCapacityHandoffs, 0)
        XCTAssertEqual(active.captureInFlight, 3)
        XCTAssertEqual(active.maximumCaptureInFlight, 3)
        XCTAssertEqual(active.demandProbeCount, 1)
        XCTAssertEqual(active.demandProbePhase, "generated-output")
        XCTAssertEqual(active.timelineRebaseCount, 0)
        XCTAssertNil(active.recordMonotonicTime)
        XCTAssertEqual(active.executableSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(error.state, .error)
        XCTAssertEqual(error.targetFrameRate, 0)
        XCTAssertEqual(error.reason, "invalid-target-hz")
    }

    func testGeneratedCompletionAloneNeverSatisfiesActivationContract() {
        let previous = observation(
            state: .priming,
            generatedPresented: 0,
            midpoint: 0,
            outputActive: false,
            displayUpdates: 10,
            recordSequence: 1,
            currentPresented: 10
        )
        let completedOnly = observation(
            state: .active,
            generatedPresented: 0,
            midpoint: 0,
            outputActive: true,
            displayUpdates: 20,
            recordSequence: 2,
            currentPresented: 11,
            outputSourceRatio: 1.20,
            currentSourceRatio: 1.0,
            generatedCompleted: 3
        )

        XCTAssertFalse(completedOnly.meetsActivationContract(after: previous))
    }

    func testBothPresentedCountersMustAdvanceForNewActivationContract() {
        let previous = observation(
            state: .priming,
            generatedPresented: 4,
            midpoint: 4,
            outputActive: false,
            displayUpdates: 20,
            recordSequence: 1
        )
        let onlyGeneratedAdvances = observation(
            state: .active,
            generatedPresented: 5,
            midpoint: 4,
            outputActive: true,
            displayUpdates: 21,
            recordSequence: 2
        )
        let onlyMidpointAdvances = observation(
            state: .active,
            generatedPresented: 4,
            midpoint: 5,
            outputActive: true,
            displayUpdates: 21,
            recordSequence: 2
        )

        XCTAssertFalse(
            onlyGeneratedAdvances.meetsActivationContract(after: previous)
        )
        XCTAssertFalse(
            onlyMidpointAdvances.meetsActivationContract(after: previous)
        )
    }

    func testExtendedActivationRequiresMatchingCurrentPresentation() {
        let previous = observation(
            state: .priming,
            generatedPresented: 0,
            midpoint: 0,
            outputActive: false,
            displayUpdates: 20,
            recordSequence: 1,
            currentPresented: 0
        )
        let midpointWithoutCurrent = observation(
            state: .active,
            generatedPresented: 1,
            midpoint: 1,
            outputActive: true,
            displayUpdates: 22,
            recordSequence: 2,
            currentPresented: 0
        )
        let completePair = observation(
            state: .active,
            generatedPresented: 1,
            midpoint: 1,
            outputActive: true,
            displayUpdates: 23,
            recordSequence: 3,
            currentPresented: 1,
            outputSourceRatio: 1.1,
            currentSourceRatio: 1.0,
            sourceCadenceLower95: 0.8
        )

        XCTAssertFalse(
            midpointWithoutCurrent.meetsActivationContract(after: previous)
        )
        XCTAssertTrue(completePair.meetsActivationContract(after: previous))
    }

    func testActivationAcceptsCaptureDepthThreeAndRejectsFour() {
        let previous = observation(
            state: .priming,
            generatedPresented: 0,
            midpoint: 0,
            outputActive: false,
            displayUpdates: 20,
            recordSequence: 1,
            currentPresented: 0
        )
        let depthThree = observation(
            state: .active,
            generatedPresented: 1,
            midpoint: 1,
            outputActive: true,
            displayUpdates: 21,
            recordSequence: 2,
            currentPresented: 1,
            outputSourceRatio: 1.1,
            currentSourceRatio: 1.0,
            sourceCadenceLower95: 0.8,
            captureInFlight: 3,
            maximumCaptureInFlight: 3,
            captureCommandBuffersOutstanding: 3
        )

        XCTAssertTrue(depthThree.meetsActivationContract(after: previous))

        var captureDepthFour = depthThree
        captureDepthFour.captureInFlight = 4
        XCTAssertFalse(
            captureDepthFour.meetsActivationContract(after: previous)
        )
        var maximumCaptureDepthFour = depthThree
        maximumCaptureDepthFour.maximumCaptureInFlight = 4
        XCTAssertFalse(
            maximumCaptureDepthFour.meetsActivationContract(after: previous)
        )
        var captureCommandBufferDepthFour = depthThree
        captureCommandBufferDepthFour.captureCommandBuffersOutstanding = 4
        XCTAssertFalse(
            captureCommandBufferDepthFour.meetsActivationContract(after: previous)
        )
    }

    func testParserKeepsPreviousBoundedTelemetryLayoutReadable() {
        let legacyBounded = record(
            processID: 4210,
            state: "active",
            target: 120,
            sourcePresentSeen: 100,
            captureReady: 99,
            generatedSubmitted: 5,
            generatedCompleted: 5,
            generatedPresented: 4,
            midpoint: 4,
            outputActive: 1,
            displayUpdates: 150,
            cadence: 90,
            reason: "current-presented",
            extended: true,
            currentPresented: 80,
            midpointAdmitted: 5,
            presentationsInFlight: 2,
            maximumPresentationsInFlight: 3,
            effectiveSlotMilliseconds: 8.333,
            recoveryMetrics: false
        )

        let observations = SteamProcessCreationObservationLog
            .parseD3DMetalFrameGenerationObservations(
                Data((legacyBounded + "\n").utf8)
            )

        XCTAssertEqual(observations.count, 1)
        XCTAssertNil(observations[0].sourceCadenceHz)
        XCTAssertNil(observations[0].outputSourceRatio)
    }

    func testParserKeepsOriginalEpochlessTelemetryLayoutReadable() {
        let legacy = [
            "FORGEPLAY_D3DMETAL_FRAMEGEN_V1",
            "4210",
            "state=monitoring",
            "target_hz=120",
            "source_present_seen=12",
            "capture_ready=0",
            "generated_submitted=0",
            "generated_completed=0",
            "generated_presented=0",
            "midpoint=0",
            "output_active=0",
            "display_updates=0",
            "cadence_hz=0",
            "reason=monitoring-source",
        ].joined(separator: "\t")
        let observations = SteamProcessCreationObservationLog
            .parseD3DMetalFrameGenerationObservations(
                Data((legacy + "\n").utf8)
            )
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].epoch, 0)
        XCTAssertEqual(observations[0].sourcePresentSeen, 12)
    }

    func testParserKeepsPreviousRecoveryTelemetryLayoutReadable() {
        let previousRecovery = record(
            processID: 4210,
            state: "active",
            target: 120,
            sourcePresentSeen: 100,
            captureReady: 99,
            generatedSubmitted: 5,
            generatedCompleted: 5,
            generatedPresented: 4,
            midpoint: 4,
            outputActive: 1,
            displayUpdates: 150,
            cadence: 90,
            reason: "current-presented",
            extended: true,
            currentPresented: 80,
            midpointAdmitted: 5,
            presentationsInFlight: 2,
            maximumPresentationsInFlight: 3,
            effectiveSlotMilliseconds: 8.333,
            sourceCadence: 80,
            outputSourceRatio: 1.05,
            latestMetrics: false
        )

        let observations = SteamProcessCreationObservationLog
            .parseD3DMetalFrameGenerationObservations(
                Data((previousRecovery + "\n").utf8)
            )

        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].sourceCadenceHz, 80)
        XCTAssertEqual(observations[0].outputSourceRatio, 1.05)
        XCTAssertNil(observations[0].originalCadenceHz)
        XCTAssertNil(observations[0].generatedCadenceHz)
    }

    func testParserKeepsPreviousCadenceTelemetryLayoutReadable() {
        let previousCadence = record(
            processID: 4210,
            state: "active",
            target: 120,
            sourcePresentSeen: 100,
            captureReady: 99,
            generatedSubmitted: 5,
            generatedCompleted: 5,
            generatedPresented: 4,
            midpoint: 4,
            outputActive: 1,
            displayUpdates: 150,
            cadence: 90,
            reason: "current-presented",
            extended: true,
            currentPresented: 80,
            midpointAdmitted: 5,
            presentationsInFlight: 2,
            maximumPresentationsInFlight: 3,
            effectiveSlotMilliseconds: 8.333,
            sourceCadence: 80,
            originalCadence: 60,
            generatedCadence: 20,
            outputSourceRatio: 1.0,
            adaptiveMetrics: false
        )

        let observations = SteamProcessCreationObservationLog
            .parseD3DMetalFrameGenerationObservations(
                Data((previousCadence + "\n").utf8)
            )
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].originalCadenceHz, 60)
        XCTAssertEqual(observations[0].generatedCadenceHz, 20)
        XCTAssertNil(observations[0].currentSourceRatio)
        XCTAssertNil(observations[0].admissionScale)
        XCTAssertNil(observations[0].outputPolicy)
    }

    func testParserAcceptsMonotonicSourcePresentationEvidence() {
        let current = record(
            processID: 4210,
            state: "active",
            target: 120,
            sourcePresentSeen: 100,
            captureReady: 80,
            generatedSubmitted: 4,
            generatedCompleted: 4,
            generatedPresented: 3,
            midpoint: 3,
            outputActive: 1,
            displayUpdates: 120,
            cadence: 110,
            reason: "midpoint-presented",
            extended: true,
            currentPresented: 80,
            midpointAdmitted: 3,
            presentationsInFlight: 0,
            maximumPresentationsInFlight: 3,
            effectiveSlotMilliseconds: 8.333,
            sourceCadence: 90,
            originalCadence: 90,
            generatedCadence: 20,
            outputSourceRatio: 1.2,
            currentSourceRatio: 1.0,
            outputPolicy: "generated-burst",
            sourcePresentAccepted: 96,
            demandProbePhase: "generated-output"
        )
        let observations = SteamProcessCreationObservationLog
            .parseD3DMetalFrameGenerationObservations(
                Data((current + "\n").utf8)
            )
        XCTAssertEqual(observations.count, 1, current)
        XCTAssertTrue(
            current.hasSuffix(
                "session_id=7\trecord_time=100.0\texecutable_sha256=" +
                    String(repeating: "a", count: 64)
            ),
            current
        )
        guard let observation = observations.first else { return }
        XCTAssertEqual(observation.epoch, 1)
        XCTAssertEqual(observation.sourcePresentAccepted, 96)
        XCTAssertEqual(observation.admissionBlockMask, 0)
        XCTAssertEqual(observation.sourceCadenceRatio, 0.75)
        XCTAssertEqual(observation.capturePoolAllocations, 1)
        XCTAssertEqual(observation.capturePoolReleases, 0)
        XCTAssertEqual(observation.capturePoolTextureCount, 6)
        XCTAssertEqual(observation.sessionIdentifier, 7)
        XCTAssertEqual(observation.recordMonotonicTime, 100)

        let preSessionSchema = current.replacingOccurrences(
            of: "\tsession_id=7",
            with: ""
        )
        let legacyRuntime = SteamProcessCreationObservationLog
            .parseD3DMetalFrameGenerationObservations(
                Data((preSessionSchema + "\n").utf8)
            )
        let legacyObservation = try? XCTUnwrap(legacyRuntime.first)
        XCTAssertEqual(legacyRuntime.count, 1, preSessionSchema)
        XCTAssertNil(legacyObservation?.sessionIdentifier)
        let preSessionPrevious = preSessionSchema
            .replacingOccurrences(
                of: "generated_presented=3",
                with: "generated_presented=2"
            )
            .replacingOccurrences(of: "midpoint=3", with: "midpoint=2")
            .replacingOccurrences(
                of: "display_updates=120",
                with: "display_updates=119"
            )
            .replacingOccurrences(
                of: "current_presented=80",
                with: "current_presented=79"
            )
        let legacyPair = SteamProcessCreationObservationLog
            .parseD3DMetalFrameGenerationObservations(
                Data((preSessionPrevious + "\n" + preSessionSchema + "\n").utf8)
            )
        XCTAssertEqual(legacyPair.count, 2)
        if legacyPair.count == 2 {
            XCTAssertFalse(
                legacyPair[1].meetsActivationContract(after: legacyPair[0])
            )
        }

        let impossible = current.replacingOccurrences(
            of: "source_present_accepted=96",
            with: "source_present_accepted=101"
        )
        XCTAssertTrue(
            SteamProcessCreationObservationLog
                .parseD3DMetalFrameGenerationObservations(
                    Data((impossible + "\n").utf8)
                )
                .isEmpty
        )
    }

    func testParserAcceptsExactSinglePathTelemetryWithoutRemovedMetrics() {
        let previous = singlePathRecord(
            state: "priming",
            generatedPresented: 2,
            midpoint: 2,
            currentPresented: 80,
            displayUpdates: 120,
            outputActive: 0,
            recordTime: 100
        )
        let current = singlePathRecord(
            state: "active",
            generatedPresented: 3,
            midpoint: 3,
            currentPresented: 81,
            displayUpdates: 121,
            outputActive: 1,
            recordTime: 101
        )
        let observations = SteamProcessCreationObservationLog
            .parseD3DMetalFrameGenerationObservations(
                Data((previous + "\n" + current + "\n").utf8)
            )

        XCTAssertEqual(observations.count, 2, current)
        guard observations.count == 2 else { return }
        XCTAssertNil(observations[1].outputUnderrunWindows)
        XCTAssertNil(observations[1].midpointStarvationWindows)
        XCTAssertNil(observations[1].admissionScale)
        XCTAssertNil(observations[1].rawDebt)
        XCTAssertNil(observations[1].outputPolicy)
        XCTAssertNil(observations[1].sourceDemandCredit)
        XCTAssertNil(observations[1].midpointDroppedPresentationStall)
        XCTAssertNil(observations[1].sourcePresentCommandBufferBound)
        XCTAssertNil(
            observations[1].sourceCaptureEncodedOnSourceCommandBuffer
        )
        XCTAssertNil(observations[1].sourceCaptureJoined)
        XCTAssertNil(observations[1].sourcePresentUncovered)
        XCTAssertTrue(
            observations[1].meetsActivationContract(after: observations[0])
        )
    }

    func testParserAcceptsCurrentWriterMetricsAtCaptureDepthThree() throws {
        let previous = currentWriterRecord(
            state: "priming",
            generatedPresented: 2,
            midpoint: 2,
            currentPresented: 80,
            displayUpdates: 120,
            outputActive: 0,
            recordTime: 100
        )
        let current = currentWriterRecord(
            state: "active",
            generatedPresented: 3,
            midpoint: 3,
            currentPresented: 81,
            displayUpdates: 121,
            outputActive: 1,
            recordTime: 101
        )
        let observations = SteamProcessCreationObservationLog
            .parseD3DMetalFrameGenerationObservations(
                Data((previous + "\n" + current + "\n").utf8)
            )

        XCTAssertEqual(observations.count, 2, current)
        let parsed = try XCTUnwrap(observations.last)
        XCTAssertEqual(parsed.captureInFlight, 3)
        XCTAssertEqual(parsed.maximumCaptureInFlight, 3)
        XCTAssertEqual(parsed.captureCommandBuffersOutstanding, 3)
        XCTAssertEqual(parsed.presentationReceiptsPending, 0)
        XCTAssertEqual(parsed.maximumPresentationReceiptsPending, 6)
        XCTAssertEqual(parsed.writerCompleted, 84)
        XCTAssertEqual(parsed.currentWriterCompleted, 81)
        XCTAssertEqual(parsed.midpointDroppedPresentationStall, 0)
        XCTAssertEqual(parsed.sourcePresentCommandBufferBound, 98)
        XCTAssertEqual(
            parsed.sourceCaptureEncodedOnSourceCommandBuffer,
            96
        )
        XCTAssertEqual(parsed.sourceCaptureJoined, 95)
        XCTAssertEqual(parsed.sourcePresentUncovered, 0)
        XCTAssertTrue(parsed.meetsActivationContract(after: observations[0]))
        for field in [
            "midpoint-dropped-presentation-stall=0",
            "source-present-command-buffer-bound=98",
            "source-capture-encoded-on-source-cb=96",
            "source-capture-joined=95",
            "source-present-uncovered=0",
            "presentation-receipts-pending=0",
            "max-presentation-receipts-pending=6",
            "writer-completed=84",
            "current-writer-completed=81",
        ] {
            XCTAssertTrue(parsed.diagnosticDescription.contains(field), field)
        }

        let overDepthRecords = [
            currentWriterRecord(
                state: "active",
                generatedPresented: 3,
                midpoint: 3,
                currentPresented: 81,
                displayUpdates: 121,
                outputActive: 1,
                recordTime: 101,
                captureInFlight: 4
            ),
            currentWriterRecord(
                state: "active",
                generatedPresented: 3,
                midpoint: 3,
                currentPresented: 81,
                displayUpdates: 121,
                outputActive: 1,
                recordTime: 101,
                maximumCaptureInFlight: 4
            ),
            currentWriterRecord(
                state: "active",
                generatedPresented: 3,
                midpoint: 3,
                currentPresented: 81,
                displayUpdates: 121,
                outputActive: 1,
                recordTime: 101,
                captureCommandBuffersOutstanding: 4
            ),
            currentWriterRecord(
                state: "active",
                generatedPresented: 3,
                midpoint: 3,
                currentPresented: 81,
                displayUpdates: 121,
                outputActive: 1,
                recordTime: 101,
                presentationReceiptsPending: 7
            ),
            currentWriterRecord(
                state: "active",
                generatedPresented: 3,
                midpoint: 3,
                currentPresented: 81,
                displayUpdates: 121,
                outputActive: 1,
                recordTime: 101,
                maximumPresentationReceiptsPending: 7
            ),
            currentWriterRecord(
                state: "active",
                generatedPresented: 3,
                midpoint: 3,
                currentPresented: 81,
                displayUpdates: 121,
                outputActive: 1,
                recordTime: 101,
                writerCompleted: 83,
                currentWriterCompleted: 81
            ),
        ]
        for overDepth in overDepthRecords {
            XCTAssertTrue(
                SteamProcessCreationObservationLog
                    .parseD3DMetalFrameGenerationObservations(
                        Data((overDepth + "\n").utf8)
                    )
                    .isEmpty,
                overDepth
            )
        }

        let overflowedWriterSum = current
            .replacingOccurrences(
                of: "generated_completed=3",
                with: "generated_completed=\(UInt64.max)"
            )
            .replacingOccurrences(
                of: "writer_completed=84",
                with: "writer_completed=\(UInt64.max)"
            )
            .replacingOccurrences(
                of: "current_writer_completed=81",
                with: "current_writer_completed=\(UInt64.max)"
            )
        XCTAssertTrue(
            SteamProcessCreationObservationLog
                .parseD3DMetalFrameGenerationObservations(
                    Data((overflowedWriterSum + "\n").utf8)
                )
                .isEmpty
        )

        let missingCurrentField = current.replacingOccurrences(
            of: "\tsource_present_uncovered=0",
            with: ""
        )
        XCTAssertTrue(
            SteamProcessCreationObservationLog
                .parseD3DMetalFrameGenerationObservations(
                    Data((missingCurrentField + "\n").utf8)
                )
                .isEmpty
        )
    }

    func testExtendedActivationRejectsOutputThatUnderRunsSource() {
        let previous = observation(
            state: .priming,
            generatedPresented: 0,
            midpoint: 0,
            outputActive: false,
            displayUpdates: 10,
            recordSequence: 1,
            currentPresented: 0,
            outputSourceRatio: 1
        )
        let slowerOutput = observation(
            state: .active,
            generatedPresented: 1,
            midpoint: 1,
            outputActive: true,
            displayUpdates: 20,
            recordSequence: 2,
            currentPresented: 1,
            outputSourceRatio: 0.8,
            currentSourceRatio: 1.0,
            sourceCadenceLower95: 0.8
        )
        let marginallySlowerOutput = observation(
            state: .active,
            generatedPresented: 1,
            midpoint: 1,
            outputActive: true,
            displayUpdates: 20,
            recordSequence: 2,
            currentPresented: 1,
            outputSourceRatio: 0.99,
            currentSourceRatio: 1.0,
            sourceCadenceLower95: 0.8
        )
        let equalOutput = observation(
            state: .active,
            generatedPresented: 1,
            midpoint: 1,
            outputActive: true,
            displayUpdates: 20,
            recordSequence: 2,
            currentPresented: 1,
            outputSourceRatio: 1.0,
            currentSourceRatio: 1.0,
            sourceCadenceLower95: 0.8
        )
        let supplementalOutput = observation(
            state: .active,
            generatedPresented: 1,
            midpoint: 1,
            outputActive: true,
            displayUpdates: 20,
            recordSequence: 2,
            currentPresented: 1,
            outputSourceRatio: 1.1,
            currentSourceRatio: 1.0,
            sourceCadenceLower95: 0.8
        )

        XCTAssertFalse(slowerOutput.meetsActivationContract(after: previous))
        XCTAssertFalse(
            marginallySlowerOutput.meetsActivationContract(after: previous)
        )
        XCTAssertFalse(equalOutput.meetsActivationContract(after: previous))
        XCTAssertTrue(
            supplementalOutput.meetsActivationContract(after: previous)
        )
    }

    func testActivationRejectsGeneratedFramesThatMaskOriginalLoss() {
        let previous = observation(
            state: .active,
            generatedPresented: 4,
            midpoint: 4,
            outputActive: true,
            displayUpdates: 20,
            recordSequence: 1,
            currentPresented: 10,
            outputSourceRatio: 1,
            currentSourceRatio: 1
        )
        let maskedOriginalLoss = observation(
            state: .active,
            generatedPresented: 5,
            midpoint: 5,
            outputActive: true,
            displayUpdates: 21,
            recordSequence: 2,
            currentPresented: 11,
            outputSourceRatio: 1.1,
            currentSourceRatio: 0.79
        )
        let usefulSupplement = observation(
            state: .active,
            generatedPresented: 5,
            midpoint: 5,
            outputActive: true,
            displayUpdates: 21,
            recordSequence: 2,
            currentPresented: 11,
            outputSourceRatio: 1.308,
            currentSourceRatio: 1.0,
            sourceCadenceLower95: 0.8
        )
        let slightOriginalLoss = observation(
            state: .active,
            generatedPresented: 5,
            midpoint: 5,
            outputActive: true,
            displayUpdates: 21,
            recordSequence: 2,
            currentPresented: 11,
            outputSourceRatio: 1.1,
            currentSourceRatio: 0.999
        )

        XCTAssertFalse(
            maskedOriginalLoss.meetsActivationContract(after: previous)
        )
        XCTAssertFalse(
            slightOriginalLoss.meetsActivationContract(after: previous)
        )
        XCTAssertTrue(
            usefulSupplement.meetsActivationContract(after: previous)
        )
    }

    func testActivationRejectsFinalCadenceBelowDirectLowerBound() {
        let previous = observation(
            state: .priming,
            generatedPresented: 0,
            midpoint: 0,
            outputActive: false,
            displayUpdates: 20,
            recordSequence: 1,
            currentPresented: 100
        )
        let collapsed = observation(
            state: .active,
            generatedPresented: 1,
            midpoint: 1,
            outputActive: true,
            displayUpdates: 21,
            recordSequence: 2,
            currentPresented: 101,
            outputSourceRatio: 1.33,
            currentSourceRatio: 1.0,
            cadenceHz: 80,
            sourceCadenceLower95: 0.8
        )
        let preserved = observation(
            state: .active,
            generatedPresented: 1,
            midpoint: 1,
            outputActive: true,
            displayUpdates: 21,
            recordSequence: 2,
            currentPresented: 101,
            outputSourceRatio: 1.33,
            currentSourceRatio: 1.0,
            cadenceHz: 96,
            sourceCadenceLower95: 0.8
        )
        let differentSession = observation(
            state: .active,
            generatedPresented: 1,
            midpoint: 1,
            outputActive: true,
            displayUpdates: 21,
            recordSequence: 2,
            currentPresented: 101,
            outputSourceRatio: 1.33,
            currentSourceRatio: 1.0,
            cadenceHz: 96,
            sourceCadenceLower95: 0.8,
            sessionIdentifier: 2
        )

        XCTAssertFalse(collapsed.meetsActivationContract(after: previous))
        XCTAssertTrue(preserved.meetsActivationContract(after: previous))
        XCTAssertFalse(differentSession.meetsActivationContract(after: previous))
    }

    func testInterleavedSamePIDSessionSnapshotsUseTheirOwnBaseline() {
        let firstA = observation(
            state: .priming,
            generatedPresented: 0,
            midpoint: 0,
            outputActive: false,
            displayUpdates: 10,
            recordSequence: 1,
            currentPresented: 10,
            sessionIdentifier: 1
        )
        let firstB = observation(
            state: .priming,
            generatedPresented: 0,
            midpoint: 0,
            outputActive: false,
            displayUpdates: 20,
            recordSequence: 2,
            currentPresented: 20,
            sessionIdentifier: 2
        )
        let activeA = observation(
            state: .active,
            generatedPresented: 1,
            midpoint: 1,
            outputActive: true,
            displayUpdates: 11,
            recordSequence: 3,
            currentPresented: 11,
            outputSourceRatio: 1.1,
            currentSourceRatio: 1.0,
            sourceCadenceLower95: 0.8,
            sessionIdentifier: 1
        )
        let activeB = observation(
            state: .active,
            generatedPresented: 1,
            midpoint: 1,
            outputActive: true,
            displayUpdates: 21,
            recordSequence: 4,
            currentPresented: 21,
            outputSourceRatio: 1.1,
            currentSourceRatio: 1.0,
            sourceCadenceLower95: 0.8,
            sessionIdentifier: 2
        )

        XCTAssertEqual(
            SteamD3DMetalFrameGenerationObservation.activationContractResults(
                in: [firstA, firstB, activeA, activeB]
            ),
            [false, false, true, true]
        )
    }

    func testTelemetryCapacityMarkerIsTerminalAndNeverActivates() throws {
        let previous = observation(
            state: .active,
            generatedPresented: 4,
            midpoint: 4,
            outputActive: true,
            displayUpdates: 100,
            recordSequence: 1,
            currentPresented: 80,
            outputSourceRatio: 1.1,
            currentSourceRatio: 1.0,
            sourceCadenceLower95: 0.7
        )
        let terminal = record(
            processID: 4210,
            state: "inactive",
            target: 120,
            sourcePresentSeen: 100,
            captureReady: 80,
            generatedSubmitted: 4,
            generatedCompleted: 4,
            generatedPresented: 4,
            midpoint: 4,
            outputActive: 0,
            displayUpdates: 100,
            cadence: 110,
            reason: "telemetry-capacity-reached",
            extended: true,
            currentPresented: 80,
            midpointAdmitted: 4,
            presentationsInFlight: 0,
            maximumPresentationsInFlight: 3,
            effectiveSlotMilliseconds: 8.333,
            sourceCadence: 90,
            originalCadence: 90,
            generatedCadence: 20,
            outputSourceRatio: 1.1,
            currentSourceRatio: 1.0,
            outputPolicy: "generated-burst",
            sourcePresentAccepted: 96,
            demandProbePhase: "generated-output"
        )
        let parsed = SteamProcessCreationObservationLog
            .parseD3DMetalFrameGenerationObservations(
                Data((terminal + "\n").utf8)
            )
        let marker = try XCTUnwrap(parsed.last)
        XCTAssertEqual(marker.state, .inactive)
        XCTAssertEqual(marker.reason, "telemetry-capacity-reached")
        XCTAssertEqual(marker.recordMonotonicTime, 100)
        XCTAssertFalse(marker.meetsActivationContract(after: previous))

        let standaloneTerminal = terminal
            .replacingOccurrences(of: "target_hz=120", with: "target_hz=0")
            .replacingOccurrences(of: "session_id=7", with: "session_id=0")
        let standaloneParsed = SteamProcessCreationObservationLog
            .parseD3DMetalFrameGenerationObservations(
                Data((standaloneTerminal + "\n").utf8)
            )
        XCTAssertEqual(standaloneParsed.count, 1, standaloneTerminal)
        XCTAssertEqual(standaloneParsed.first?.state, .inactive)

        let lateActive = record(
            processID: 4210,
            state: "active",
            target: 120,
            sourcePresentSeen: 101,
            captureReady: 81,
            generatedSubmitted: 5,
            generatedCompleted: 5,
            generatedPresented: 5,
            midpoint: 5,
            outputActive: 1,
            displayUpdates: 101,
            cadence: 111,
            reason: "midpoint-presented",
            extended: true,
            currentPresented: 81,
            midpointAdmitted: 5,
            presentationsInFlight: 0,
            maximumPresentationsInFlight: 3,
            effectiveSlotMilliseconds: 8.333,
            sourceCadence: 90,
            originalCadence: 90,
            generatedCadence: 21,
            outputSourceRatio: 1.1,
            currentSourceRatio: 1.0,
            outputPolicy: "augmenting",
            sourcePresentAccepted: 97,
            demandProbePhase: "none"
        )
        let terminalThenLate = SteamProcessCreationObservationLog
            .parseD3DMetalFrameGenerationObservations(
                Data((terminal + "\n" + lateActive + "\n").utf8)
            )
        XCTAssertEqual(terminalThenLate.count, 1)
        XCTAssertEqual(terminalThenLate.last?.reason, "telemetry-capacity-reached")
    }

    func testNVIDIARouteParserPreservesRequestedCompatibilitySelection() throws {
        let record = [
            "FORGEPLAY_GAME_RENDERER_ROUTE_V2",
            "1776",
            "requested=d3dMetalNVIDIA | applied=d3dMetal | " +
                "planned-profile=d3dMetal | planned-owner=d3dMetal | " +
                "planned-components-x64=d3dmetal | " +
                "planned-components-x86=unreported | actual-loaded=unobserved | " +
                "reason=manual-session-d3dmetal | evidence=host-policy | " +
                "correlation=run-a | C:\\Games\\Game.exe"
        ].joined(separator: "\t")

        let routes = SteamProcessCreationObservationLog
            .parseGameRendererObservations(Data((record + "\n").utf8))
        let route = try XCTUnwrap(routes.first)

        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(route.rendererPolicy, .d3dMetal)
        XCTAssertEqual(route.rendererSelection, .d3dMetalNVIDIA)
        XCTAssertEqual(route.correlationIdentifier, "run-a")
    }

    func testNVIDIAFrameGenerationCorrelationBridgesDarwinAndWindowsPIDs() {
        let main = rendererRoute(
            sequence: 10,
            processID: 100,
            executable: "C:\\Games\\Main.exe"
        )
        let helper = rendererRoute(
            sequence: 20,
            processID: 9_001,
            executable: "C:\\Games\\Helper.exe"
        )
        let next = rendererRoute(
            sequence: 100,
            processID: 300,
            executable: "C:\\Games\\Next.exe"
        )
        let frameSnapshots = [
            observation(
                state: .priming,
                generatedPresented: 0,
                midpoint: 0,
                outputActive: false,
                displayUpdates: 1,
                recordSequence: 110,
                processID: 9_001,
                executableSHA256: SteamGameLaunchDiagnosticAnalyzer
                    .frameGenerationExecutableSHA256(main.executable)
            ),
            observation(
                state: .active,
                generatedPresented: 1,
                midpoint: 1,
                outputActive: true,
                displayUpdates: 10,
                recordSequence: 120,
                processID: 9_001,
                executableSHA256: SteamGameLaunchDiagnosticAnalyzer
                    .frameGenerationExecutableSHA256(main.executable)
            ),
            observation(
                state: .active,
                generatedPresented: 1,
                midpoint: 1,
                outputActive: true,
                displayUpdates: 10,
                recordSequence: 130,
                processID: 9_002,
                executableSHA256: SteamGameLaunchDiagnosticAnalyzer
                    .frameGenerationExecutableSHA256(next.executable)
            )
        ]
        let read = SteamProcessObservationReadResult(
            processes: [],
            gameRendererObservations: [main, helper, next],
            gameRendererErrors: [],
            gameRendererEnvironmentFailures: [],
            gameRendererFallbacks: [],
            gameRendererModuleLoads: [
                providerLoad(for: main, sequence: 11),
                providerLoad(for: next, sequence: 101)
            ],
            gameRendererBaseHelpers: [],
            d3dMetalFrameGenerationObservations: frameSnapshots,
            state: .complete,
            issues: []
        )

        XCTAssertEqual(
            SteamGameLaunchDiagnosticAnalyzer
                .correlatedD3DMetalFrameGenerationObservations(
                    for: main,
                    in: read
                )
                .map(\.processID),
            [9_001, 9_001]
        )
        XCTAssertTrue(
            SteamGameLaunchDiagnosticAnalyzer
                .correlatedD3DMetalFrameGenerationObservations(
                    for: helper,
                    in: read
                )
                .isEmpty
        )
        XCTAssertEqual(
            SteamGameLaunchDiagnosticAnalyzer
                .correlatedD3DMetalFrameGenerationObservations(
                    for: next,
                    in: read
                )
                .map(\.processID),
            [9_002]
        )
    }

    func testNVIDIAFrameGenerationCorrelationSplitsReusedNativePID() {
        let first = rendererRoute(
            sequence: 10,
            processID: 100,
            executable: "C:\\Games\\Same.exe"
        )
        let second = rendererRoute(
            sequence: 100,
            processID: 200,
            executable: "C:\\Games\\Same.exe"
        )
        let executableSHA = SteamGameLaunchDiagnosticAnalyzer
            .frameGenerationExecutableSHA256(first.executable)
        let snapshots = [
            observation(
                state: .active,
                generatedPresented: 1,
                midpoint: 1,
                outputActive: true,
                displayUpdates: 10,
                recordSequence: 20,
                processID: 9_001,
                executableSHA256: executableSHA
            ),
            observation(
                state: .active,
                generatedPresented: 2,
                midpoint: 2,
                outputActive: true,
                displayUpdates: 20,
                recordSequence: 110,
                processID: 9_001,
                executableSHA256: executableSHA
            )
        ]
        let read = SteamProcessObservationReadResult(
            processes: [],
            gameRendererObservations: [first, second],
            gameRendererErrors: [],
            gameRendererEnvironmentFailures: [],
            gameRendererFallbacks: [],
            gameRendererModuleLoads: [
                providerLoad(for: first, sequence: 11),
                providerLoad(for: second, sequence: 101)
            ],
            gameRendererBaseHelpers: [],
            d3dMetalFrameGenerationObservations: snapshots,
            state: .complete,
            issues: []
        )

        XCTAssertEqual(
            SteamGameLaunchDiagnosticAnalyzer
                .correlatedD3DMetalFrameGenerationObservations(
                    for: first,
                    in: read
                )
                .map(\.recordSequence),
            [20]
        )
        XCTAssertEqual(
            SteamGameLaunchDiagnosticAnalyzer
                .correlatedD3DMetalFrameGenerationObservations(
                    for: second,
                    in: read
                )
                .map(\.recordSequence),
            [110]
        )
    }

    private func record(
        processID: Int,
        state: String,
        target: Int,
        sourcePresentSeen: Int,
        captureReady: Int,
        generatedSubmitted: Int,
        generatedCompleted: Int,
        generatedPresented: Int,
        midpoint: Int,
        outputActive: Int,
        displayUpdates: Int,
        cadence: Double,
        reason: String,
        extended: Bool = false,
        currentPresented: Int = 0,
        midpointAdmitted: Int = 0,
        presentationsInFlight: Int = 0,
        maximumPresentationsInFlight: Int = 0,
        effectiveSlotMilliseconds: Double = 0,
        sourceCadence: Double = 0,
        originalCadence: Double = 0,
        generatedCadence: Double = 0,
        outputSourceRatio: Double = 1,
        currentSourceRatio: Double = 1,
        admissionScale: Double = 1,
        rawDebt: Double = 0,
        outputPolicy: String = "augmenting",
        recoveryMetrics: Bool = true,
        latestMetrics: Bool = true,
        adaptiveMetrics: Bool = true,
        orderedMetrics: Bool = true,
        sourcePresentAccepted: Int? = nil,
        captureInFlight: Int = 0,
        maximumCaptureInFlight: Int = 1,
        demandProbePhase: String = "current-replay",
        executableSHA256: String = String(repeating: "a", count: 64)
    ) -> String {
        var fields = [
            "FORGEPLAY_D3DMETAL_FRAMEGEN_V1",
            String(processID),
            "state=\(state)",
            "target_hz=\(target)",
            "epoch=\(state == "error" ? 0 : 1)",
            "source_present_seen=\(sourcePresentSeen)",
            "capture_ready=\(captureReady)",
            "generated_submitted=\(generatedSubmitted)",
            "generated_completed=\(generatedCompleted)",
            "generated_presented=\(generatedPresented)",
            "midpoint=\(midpoint)",
            "output_active=\(outputActive)",
            "display_updates=\(displayUpdates)",
            "cadence_hz=\(cadence)",
            "reason=\(reason)"
        ]
        if extended {
            fields.append(contentsOf: [
                "current_presented=\(currentPresented)",
                "midpoint_admitted=\(midpointAdmitted)",
                "midpoint_dropped_late=0",
                "midpoint_dropped_superseded=0",
                "presentations_in_flight=\(presentationsInFlight)",
                "max_presentations_in_flight=\(maximumPresentationsInFlight)",
                "generation_reserved=0",
                "generation_outstanding=0",
                "effective_slot_ms=\(effectiveSlotMilliseconds)",
                "capture_skipped_busy=0",
                "capture_inflight=\(captureInFlight)",
                "max_capture_inflight=\(maximumCaptureInFlight)"
            ])
            if recoveryMetrics {
                fields.append(contentsOf: [
                    "capture_busy_episode=0",
                    "capture_outstanding_ms=0",
                    "output_underrun_windows=0",
                    "midpoint_starvation_windows=0",
                    "empty_display_updates=0",
                    "display_resume_count=1",
                    "source_cadence_hz=\(sourceCadence)"
                ])
                if latestMetrics {
                    fields.append(contentsOf: [
                        "original_cadence_hz=\(originalCadence)",
                        "generated_cadence_hz=\(generatedCadence)"
                    ])
                }
                fields.append(contentsOf: [
                    "output_source_ratio=\(outputSourceRatio)",
                    "presentation_stall_checks=0"
                ])
                if latestMetrics {
                    if adaptiveMetrics {
                        fields.append(contentsOf: [
                            "current_source_ratio=\(currentSourceRatio)",
                            "admission_scale=\(admissionScale)",
                            "raw_debt=\(rawDebt)",
                            "output_policy=\(outputPolicy)"
                        ])
                        if orderedMetrics {
                            fields.append(contentsOf: [
                                "source_demand_credit=0.5",
                                "ready_bundle_depth=1",
                                "max_ready_bundle_depth=2",
                                "current_queue_capacity_handoffs=0",
                                "demand_probe_count=1",
                                "demand_probe_phase=\(demandProbePhase)",
                                "timeline_rebase_count=0"
                            ])
                            if let sourcePresentAccepted {
                                fields.append(contentsOf: [
                                    "source_present_accepted=\(sourcePresentAccepted)",
                                    "admission_block_mask=0",
                                    "source_q=0.75",
                                    "source_q_lower95=0.70",
                                    "source_q_upper95=0.80",
                                    "capture_cb_outstanding=0",
                                    "display_cb_outstanding=0",
                                    "capture_pool_allocations=1",
                                    "capture_pool_releases=0",
                                    "capture_pool_textures=6",
                                    "session_id=7",
                                    "record_time=100.0",
                                ])
                            }
                        }
                    }
                }
                fields.append("executable_sha256=\(executableSHA256)")
            }
        }
        return fields.joined(separator: "\t")
    }

    private func singlePathRecord(
        state: String,
        generatedPresented: Int,
        midpoint: Int,
        currentPresented: Int,
        displayUpdates: Int,
        outputActive: Int,
        recordTime: Double
    ) -> String {
        let base = record(
            processID: 4210,
            state: state,
            target: 120,
            sourcePresentSeen: 100,
            captureReady: 80,
            generatedSubmitted: generatedPresented,
            generatedCompleted: generatedPresented,
            generatedPresented: generatedPresented,
            midpoint: midpoint,
            outputActive: outputActive,
            displayUpdates: displayUpdates,
            cadence: 110,
            reason: state == "active"
                ? "midpoint-presented" : "capture-ready",
            extended: false
        )
        return ([base] + [
            "current_presented=\(currentPresented)",
            "midpoint_admitted=\(midpoint)",
            "midpoint_dropped_late=0",
            "midpoint_dropped_superseded=0",
            "presentations_in_flight=0",
            "max_presentations_in_flight=3",
            "generation_reserved=0",
            "generation_outstanding=0",
            "effective_slot_ms=8.333",
            "capture_skipped_busy=0",
            "capture_inflight=0",
            "max_capture_inflight=2",
            "capture_busy_episode=0",
            "capture_outstanding_ms=0",
            "empty_display_updates=0",
            "display_resume_count=1",
            "source_cadence_hz=90",
            "original_cadence_hz=90",
            "generated_cadence_hz=20",
            "output_source_ratio=1.2",
            "current_source_ratio=1.0",
            "presentation_stall_checks=0",
            "source_present_accepted=96",
            "source_q=0.75",
            "source_q_lower95=0.70",
            "source_q_upper95=0.80",
            "capture_cb_outstanding=0",
            "display_cb_outstanding=0",
            "capture_pool_allocations=6",
            "capture_pool_releases=0",
            "capture_pool_textures=6",
            "record_time=\(recordTime)",
            "session_id=7",
            "executable_sha256=\(String(repeating: "a", count: 64))"
        ]).joined(separator: "\t")
    }

    private func currentWriterRecord(
        state: String,
        generatedPresented: Int,
        midpoint: Int,
        currentPresented: Int,
        displayUpdates: Int,
        outputActive: Int,
        recordTime: Double,
        presentationReceiptsPending: Int = 0,
        maximumPresentationReceiptsPending: Int = 6,
        writerCompleted: Int? = nil,
        currentWriterCompleted: Int? = nil,
        captureInFlight: Int = 3,
        maximumCaptureInFlight: Int = 3,
        captureCommandBuffersOutstanding: Int = 3
    ) -> String {
        let currentWriterCompleted = currentWriterCompleted ?? currentPresented
        let writerCompleted = writerCompleted ??
            currentWriterCompleted + generatedPresented
        let base = record(
            processID: 4210,
            state: state,
            target: 120,
            sourcePresentSeen: 100,
            captureReady: 80,
            generatedSubmitted: generatedPresented,
            generatedCompleted: generatedPresented,
            generatedPresented: generatedPresented,
            midpoint: midpoint,
            outputActive: outputActive,
            displayUpdates: displayUpdates,
            cadence: 110,
            reason: state == "active"
                ? "midpoint-presented" : "capture-ready",
            extended: false
        )
        return ([base] + [
            "current_presented=\(currentPresented)",
            "midpoint_admitted=\(midpoint)",
            "midpoint_dropped_late=0",
            "midpoint_dropped_superseded=0",
            "midpoint_dropped_presentation_stall=0",
            "presentations_in_flight=0",
            "max_presentations_in_flight=3",
            "presentation_receipts_pending=\(presentationReceiptsPending)",
            "max_presentation_receipts_pending=\(maximumPresentationReceiptsPending)",
            "writer_completed=\(writerCompleted)",
            "current_writer_completed=\(currentWriterCompleted)",
            "generation_reserved=0",
            "generation_outstanding=0",
            "effective_slot_ms=8.333",
            "capture_skipped_busy=0",
            "capture_inflight=\(captureInFlight)",
            "max_capture_inflight=\(maximumCaptureInFlight)",
            "capture_busy_episode=0",
            "capture_outstanding_ms=0",
            "empty_display_updates=0",
            "display_resume_count=1",
            "source_cadence_hz=90",
            "original_cadence_hz=90",
            "generated_cadence_hz=20",
            "output_source_ratio=1.2",
            "current_source_ratio=1.0",
            "source_present_accepted=96",
            "source_q=0.75",
            "source_q_lower95=0.70",
            "source_q_upper95=0.80",
            "capture_cb_outstanding=\(captureCommandBuffersOutstanding)",
            "display_cb_outstanding=0",
            "capture_pool_allocations=1",
            "capture_pool_releases=0",
            "capture_pool_textures=6",
            "record_time=\(recordTime)",
            "session_id=7",
            "presentation_stall_checks=0",
            "source_present_command_buffer_bound=98",
            "source_capture_encoded_on_source_cb=96",
            "source_capture_joined=95",
            "source_present_uncovered=0",
            "executable_sha256=\(String(repeating: "a", count: 64))"
        ]).joined(separator: "\t")
    }

    private func observation(
        state: SteamD3DMetalFrameGenerationState,
        generatedPresented: UInt64,
        midpoint: UInt64,
        outputActive: Bool,
        displayUpdates: UInt64,
        recordSequence: Int,
        processID: Int32 = 4210,
        currentPresented: UInt64? = nil,
        outputSourceRatio: Double? = nil,
        currentSourceRatio: Double? = nil,
        cadenceHz: Double = 120,
        sourceCadenceLower95: Double? = nil,
        presentationsInFlight: UInt32? = 0,
        captureInFlight: UInt32? = 0,
        maximumCaptureInFlight: UInt32? = 3,
        captureCommandBuffersOutstanding: UInt32? = 0,
        sessionIdentifier: UInt64? = 1,
        recordMonotonicTime: Double? = nil,
        executableSHA256: String? = String(repeating: "a", count: 64),
        generatedCompleted: UInt64 = 2
    ) -> SteamD3DMetalFrameGenerationObservation {
        SteamD3DMetalFrameGenerationObservation(
            recordSequence: recordSequence,
            processID: processID,
            state: state,
            targetFrameRate: 120,
            sourcePresentSeen: 10,
            captureReady: 10,
            generatedSubmitted: 2,
            generatedCompleted: generatedCompleted,
            generatedPresented: generatedPresented,
            midpointPresented: midpoint,
            outputActive: outputActive,
            displayUpdates: displayUpdates,
            cadenceHz: cadenceHz,
            reason: "test",
            currentPresented: currentPresented,
            presentationsInFlight: presentationsInFlight,
            maximumPresentationsInFlight: 3,
            captureInFlight: captureInFlight,
            maximumCaptureInFlight: maximumCaptureInFlight,
            outputSourceRatio: outputSourceRatio,
            currentSourceRatio: currentSourceRatio,
            sourceCadenceRatio: 0.75,
            sourceCadenceLower95: sourceCadenceLower95,
            captureCommandBuffersOutstanding:
                captureCommandBuffersOutstanding,
            displayCommandBuffersOutstanding: 0,
            sessionIdentifier: sessionIdentifier,
            recordMonotonicTime:
                recordMonotonicTime ?? Double(recordSequence),
            executableSHA256: executableSHA256
        )
    }

    private func rendererRoute(
        sequence: Int,
        processID: Int32,
        executable: String
    ) -> SteamGameRendererObservation {
        SteamGameRendererObservation(
            recordSequence: sequence,
            processID: processID,
            rendererPolicy: .d3dMetal,
            rendererSelection: .d3dMetalNVIDIA,
            plannedProfile: "d3dMetal",
            plannedComponentOwnership: .d3dMetal,
            actualLoadedState: .unobserved,
            routingReason: "manual-session-d3dmetal",
            routingEvidence: "host-policy",
            correlationIdentifier: "run-a",
            executable: executable
        )
    }

    private func providerLoad(
        for route: SteamGameRendererObservation,
        sequence: Int
    ) -> SteamGameRendererModuleLoadObservation {
        SteamGameRendererModuleLoadObservation(
            recordSequence: sequence,
            processID: route.processID,
            state: .loaded,
            module: "nvapi64.dll",
            actualPath: "C:\\windows\\system32\\nvapi64.dll",
            pathOwnership: .verified,
            plannedProfile: route.plannedProfile,
            plannedOwner: route.plannedComponentOwnership.rawValue,
            statusCode: 0,
            correlationIdentifier: "run-a",
            executable: route.executable
        )
    }
}
