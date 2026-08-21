import AppKit
import Darwin
import Foundation
import SwiftData
import XCTest
@testable import ForgePlay

final class StartupPerformanceContractTests: XCTestCase {
    @MainActor
    func testMainWindowKeepsLaunchSplashUntilBootstrapAndRootStartupComplete() throws {
        XCTAssertEqual(ForgePlayLaunchSplashPolicy.assetName, "LaunchSplash")
        XCTAssertNotNil(NSImage(named: ForgePlayLaunchSplashPolicy.assetName))

        let splashURL = try projectRoot().appending(
            path: "Resources/Assets.xcassets/LaunchSplash.imageset/LaunchSplash.png"
        )
        let splashData = try Data(contentsOf: splashURL)
        let splashBitmap = try XCTUnwrap(NSBitmapImageRep(data: splashData))
        XCTAssertEqual(splashBitmap.pixelsWide, 1_600)
        XCTAssertEqual(splashBitmap.pixelsHigh, 1_000)

        let source = try projectSource("Sources/ForgePlay/ForgePlayApp.swift")
        let mainWindowStart = try XCTUnwrap(
            source.range(of: "WindowGroup(id: ForgePlaySceneID.main) {")?.lowerBound
        )
        let settingsStart = try XCTUnwrap(
            source.range(of: "\n        Settings {")?.lowerBound
        )
        let mainWindow = String(source[mainWindowStart..<settingsStart])
        let windowContentStart = try XCTUnwrap(
            source.range(of: "    private var windowContent: some View {")?.lowerBound
        )
        let settingsContentStart = try XCTUnwrap(
            source.range(
                of: "    private var settingsContent: some View {",
                range: windowContentStart..<source.endIndex
            )?.lowerBound
        )
        let windowContent = String(source[windowContentStart..<settingsContentStart])
        let splashStart = try XCTUnwrap(
            source.range(of: "struct ForgePlayLaunchSplashView: View")?.lowerBound
        )
        let loadingStart = try XCTUnwrap(
            source.range(of: "struct ForgePlayStartupLoadingView: View")?.lowerBound
        )
        let settingsViewStart = try XCTUnwrap(
            source.range(of: "private struct SettingsSceneView: View")?.lowerBound
        )
        let splashView = String(source[splashStart..<loadingStart])
        let loadingView = String(source[loadingStart..<settingsViewStart])
        let firstYield = try XCTUnwrap(mainWindow.range(of: "await Task.yield()")?.lowerBound)
        let bootstrapStart = try XCTUnwrap(
            mainWindow.range(of: "modelContainerBootstrap.startIfNeeded()")?.lowerBound
        )

        XCTAssertLessThan(firstYield, bootstrapStart)
        XCTAssertFalse(mainWindow.contains("Task.sleep"))
        XCTAssertFalse(source.contains("minimumVisibleDuration"))
        XCTAssertTrue(windowContent.contains("switch modelContainerBootstrap.result"))
        XCTAssertTrue(windowContent.contains("case .none:"))
        XCTAssertTrue(windowContent.contains("ForgePlayLaunchSplashView()"))
        XCTAssertTrue(splashView.contains("Image(ForgePlayLaunchSplashPolicy.assetName)"))
        XCTAssertTrue(splashView.contains(".scaledToFill()"))
        XCTAssertTrue(splashView.contains(".background(Color.black)"))
        XCTAssertTrue(splashView.contains(".accessibilityLabel(Text(\"ForgePlay\"))"))
        XCTAssertTrue(splashView.contains("appState.localized(\"실행 준비 중…\")"))
        XCTAssertFalse(loadingView.contains("Task.sleep"))
        XCTAssertTrue(loadingView.contains("Image(nsImage: NSApplication.shared.applicationIconImage)"))
        XCTAssertTrue(loadingView.contains("Text(\"ForgePlay\")"))
        XCTAssertTrue(loadingView.contains("appState.localized(\"실행 준비 중…\")"))
        XCTAssertTrue(loadingView.contains(".accessibilityLabel(Text(\"ForgePlay\"))"))
        XCTAssertTrue(loadingView.contains(".accessibilityValue(Text(appState.localized(\"실행 준비 중…\")))"))
    }

    func testRootStartupPresentationRemainsLoadingUntilSuccess() {
        let initial = ForgePlayRootStartupPresentation.loading

        XCTAssertTrue(initial.showsBrandedLoading)

        let completed = initial.transitioned(for: .succeeded)
        XCTAssertEqual(completed, .ready)
        XCTAssertFalse(completed.showsBrandedLoading)
    }

    func testRootStartupPresentationRevealsRecoveryForFailureAndUserIntervention() {
        for event in [
            ForgePlayRootStartupEvent.failed,
            .requiresUserIntervention
        ] {
            let presentation = ForgePlayRootStartupPresentation.loading
                .transitioned(for: event)

            XCTAssertEqual(presentation, .recovery)
            XCTAssertFalse(presentation.showsBrandedLoading)
        }
    }

    func testSetupWorkflowSynchronizationAlwaysRecomputesLiveReadiness() throws {
        let source = try projectSource("Sources/ForgePlay/App/AppServices.swift")
        let start = try XCTUnwrap(
            source.range(of: "    func synchronizeSetupWorkflow(")?.lowerBound
        )
        let end = try XCTUnwrap(
            source.range(
                of: "    func refreshSetupWorkflow(",
                range: start..<source.endIndex
            )?.lowerBound
        )
        let synchronize = String(source[start..<end])

        XCTAssertTrue(
            synchronize.contains("setupWorkflowCoordinator.computeReadiness(")
        )
        XCTAssertTrue(synchronize.contains("setupWorkflowRefreshAttemptGate.issue()"))
        XCTAssertTrue(synchronize.contains("cancelActiveSetupWorkflowRefresh()"))
        XCTAssertTrue(synchronize.contains("appState.updateSetupStage(readiness: readiness)"))
        XCTAssertFalse(synchronize.contains("cached"))
        XCTAssertFalse(source.contains("SetupWorkflowSynchronizationMemo"))
        XCTAssertFalse(source.contains("CompletedSetupWorkflowRefresh"))
    }

    func testSynchronousReadinessPublicationInvalidatesSuspendedAsyncCommit() {
        var gate = SetupWorkflowRefreshAttemptGate()
        var published = "initial"

        let suspendedAsync = gate.issue()
        XCTAssertTrue(gate.begin(suspendedAsync))

        let synchronousPublication = gate.issue()
        XCTAssertTrue(gate.finish(suspendedAsync))
        published = "synchronous-new"

        if gate.permitsCommit(suspendedAsync) {
            published = "stale-async"
        }

        XCTAssertEqual(published, "synchronous-new")
        XCTAssertTrue(gate.isLatest(synchronousPublication))
        XCTAssertFalse(gate.permitsCommit(suspendedAsync))
        XCTAssertNil(gate.activeTicket)
    }

    func testSetupWorkflowTicketGateRejectsReverseABCWakeup() {
        var gate = SetupWorkflowRefreshAttemptGate()

        let a = gate.issue()
        XCTAssertTrue(gate.begin(a))
        let b = gate.issue()
        XCTAssertTrue(gate.finish(a))
        let c = gate.issue()

        XCTAssertFalse(gate.begin(b))
        XCTAssertTrue(gate.begin(c))
        XCTAssertFalse(gate.permitsCommit(a))
        XCTAssertFalse(gate.permitsCommit(b))
        XCTAssertTrue(gate.permitsCommit(c))
        XCTAssertFalse(gate.finish(b))
        XCTAssertTrue(gate.finish(c))
        XCTAssertNil(gate.activeTicket)
    }

    @MainActor
    func testCancellingOneSharedWaiterLeavesUnderlyingWorkForRemainingWaiter() async throws {
        let registry = SetupWorkflowRefreshWaiterRegistry<String>()
        let cancellationProbe = SetupWorkflowFinalWaiterCancellationProbe()
        let first = Task { @MainActor in
            await setupWorkflowWaiterOutcome(
                registry: registry,
                cancellationProbe: cancellationProbe
            )
        }
        let second = Task { @MainActor in
            await setupWorkflowWaiterOutcome(
                registry: registry,
                cancellationProbe: cancellationProbe
            )
        }
        try await waitForSetupWorkflowWaiterCount(2, registry: registry)

        first.cancel()

        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .cancelled)
        XCTAssertEqual(registry.waiterCount, 1)
        XCTAssertEqual(cancellationProbe.count, 0)
        XCTAssertEqual(registry.complete(with: .success("ready")), 1)
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .value("ready"))
        XCTAssertEqual(registry.waiterCount, 0)
    }

    @MainActor
    func testSoleWaiterCancellationInvalidatesBeforeLateCompletion() async throws {
        let registry = SetupWorkflowRefreshWaiterRegistry<String>()
        let cancellationProbe = SetupWorkflowFinalWaiterCancellationProbe()
        let waiter = Task { @MainActor in
            await setupWorkflowWaiterOutcome(
                registry: registry,
                cancellationProbe: cancellationProbe
            )
        }
        try await waitForSetupWorkflowWaiterCount(1, registry: registry)

        waiter.cancel()

        let outcome = await waiter.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(cancellationProbe.count, 1)
        XCTAssertEqual(registry.waiterCount, 0)
        XCTAssertEqual(registry.complete(with: .success("late")), 0)
    }

    @MainActor
    func testWaiterCompletionCancellationRaceResumesExactlyOnceInBothOrders() async throws {
        do {
            let registry = SetupWorkflowRefreshWaiterRegistry<String>()
            let cancellationProbe = SetupWorkflowFinalWaiterCancellationProbe()
            let waiter = Task { @MainActor in
                await setupWorkflowWaiterOutcome(
                    registry: registry,
                    cancellationProbe: cancellationProbe
                )
            }
            try await waitForSetupWorkflowWaiterCount(1, registry: registry)

            XCTAssertEqual(registry.complete(with: .success("completed")), 1)
            waiter.cancel()

            let outcome = await waiter.value
            XCTAssertEqual(outcome, .cancelled)
            XCTAssertEqual(cancellationProbe.count, 0)
            XCTAssertEqual(registry.complete(with: .success("duplicate")), 0)
        }

        do {
            let registry = SetupWorkflowRefreshWaiterRegistry<String>()
            let cancellationProbe = SetupWorkflowFinalWaiterCancellationProbe()
            let waiter = Task { @MainActor in
                await setupWorkflowWaiterOutcome(
                    registry: registry,
                    cancellationProbe: cancellationProbe
                )
            }
            try await waitForSetupWorkflowWaiterCount(1, registry: registry)

            waiter.cancel()

            let outcome = await waiter.value
            XCTAssertEqual(outcome, .cancelled)
            XCTAssertEqual(cancellationProbe.count, 1)
            XCTAssertEqual(registry.complete(with: .success("late")), 0)
        }
    }

    func testSetupReadinessObservationKeyIncludesEveryLiveInput() throws {
        let record = SteamLaunchRecordLookup.ReadinessFingerprint.Record(
            id: "launch-a",
            startedAt: Date(timeIntervalSince1970: 1),
            verificationStatus: "rendered",
            surface: "library",
            hostAppSessionID: "session-a",
            environmentGenerationID: "generation-a",
            exitCode: 0
        )
        let fingerprint = SteamLaunchRecordLookup.ReadinessFingerprint(records: [record])
        let baseline = SetupReadinessObservationKey(
            environmentRevision: 1,
            hasSteamReferences: true,
            launchReadinessFingerprint: fingerprint,
            selectedRootPath: "/root-a",
            runtimeExecutablePath: "/runtime-a",
            rendererSelection: "renderer-a",
            videoMemorySelection: "video-a"
        )
        let variants = [
            SetupReadinessObservationKey(
                environmentRevision: 2,
                hasSteamReferences: true,
                launchReadinessFingerprint: fingerprint,
                selectedRootPath: "/root-a",
                runtimeExecutablePath: "/runtime-a",
                rendererSelection: "renderer-a",
                videoMemorySelection: "video-a"
            ),
            SetupReadinessObservationKey(
                environmentRevision: 1,
                hasSteamReferences: false,
                launchReadinessFingerprint: fingerprint,
                selectedRootPath: "/root-a",
                runtimeExecutablePath: "/runtime-a",
                rendererSelection: "renderer-a",
                videoMemorySelection: "video-a"
            ),
            SetupReadinessObservationKey(
                environmentRevision: 1,
                hasSteamReferences: true,
                launchReadinessFingerprint: .init(records: []),
                selectedRootPath: "/root-a",
                runtimeExecutablePath: "/runtime-a",
                rendererSelection: "renderer-a",
                videoMemorySelection: "video-a"
            ),
            SetupReadinessObservationKey(
                environmentRevision: 1,
                hasSteamReferences: true,
                launchReadinessFingerprint: fingerprint,
                selectedRootPath: "/root-b",
                runtimeExecutablePath: "/runtime-a",
                rendererSelection: "renderer-a",
                videoMemorySelection: "video-a"
            ),
            SetupReadinessObservationKey(
                environmentRevision: 1,
                hasSteamReferences: true,
                launchReadinessFingerprint: fingerprint,
                selectedRootPath: "/root-a",
                runtimeExecutablePath: "/runtime-b",
                rendererSelection: "renderer-a",
                videoMemorySelection: "video-a"
            ),
            SetupReadinessObservationKey(
                environmentRevision: 1,
                hasSteamReferences: true,
                launchReadinessFingerprint: fingerprint,
                selectedRootPath: "/root-a",
                runtimeExecutablePath: "/runtime-a",
                rendererSelection: "renderer-b",
                videoMemorySelection: "video-a"
            ),
            SetupReadinessObservationKey(
                environmentRevision: 1,
                hasSteamReferences: true,
                launchReadinessFingerprint: fingerprint,
                selectedRootPath: "/root-a",
                runtimeExecutablePath: "/runtime-a",
                rendererSelection: "renderer-a",
                videoMemorySelection: "video-b"
            )
        ]

        XCTAssertEqual(variants.count, 7)
        for variant in variants {
            XCTAssertNotEqual(variant, baseline)
        }

        let source = try projectSource("Sources/ForgePlay/App/AppServices.swift")
        let start = try XCTUnwrap(
            source.range(of: "    func setupReadinessObservationKey(")?.lowerBound
        )
        let end = try XCTUnwrap(
            source.range(
                of: "    private func performSetupWorkflowRefresh(",
                range: start..<source.endIndex
            )?.lowerBound
        )
        let builder = String(source[start..<end])
        for expectedProjection in [
            "environmentRevision: steamEnvironmentRevision",
            "hasSteamReferences: hasSteamReferences",
            "launchReadinessFingerprint: launchReadinessFingerprint",
            "selectedRootPath: appState.selectedRootURL?.standardizedFileURL.path",
            "runtimeExecutablePath: appState.runtimeExecutableURL?.standardizedFileURL.path",
            "rendererSelection: appState.steamRendererPolicySelection.rawValue",
            "videoMemorySelection: appState.steamVideoMemorySelection.rawValue"
        ] {
            XCTAssertTrue(builder.contains(expectedProjection), expectedProjection)
        }
    }

    func testNewestFirstLaunchLookupsMatchArbitraryOrderContracts() {
        let now = Date()
        let records = (0..<40).map { index in
            let hostAppSessionID: String = switch index {
            case 2: "library-session-a"
            case 3: "library-session-b"
            case 7: "current-session"
            default: "other-session"
            }
            let record = LaunchRecord(
                id: "launch-\(index)",
                prefixId: PrefixIdentifier.steamShared,
                commandKind: "launchSteam",
                startedAt: now.addingTimeInterval(TimeInterval(-index)),
                exitCode: Int32(index),
                hostAppSessionID: hostAppSessionID,
                environmentGenerationID: "generation"
            )
            if index == 2 || index == 3 {
                record.markSteamUISurface(.library)
            }
            return record
        }
        let shuffled = Array(records.reversed())
        let identity = SteamEnvironmentIdentity(
            generationID: "generation",
            createdAt: nil
        )

        XCTAssertEqual(
            SteamLaunchRecordLookup.newestFirstStateFingerprint(from: records),
            SteamLaunchRecordLookup.stateFingerprint(from: shuffled)
        )
        let readinessFingerprint = SteamLaunchRecordLookup
            .newestFirstReadinessFingerprint(
                from: records,
                environmentIdentity: identity,
                currentAppSessionID: "current-session"
            )
        XCTAssertEqual(readinessFingerprint.records.count, 3)
        var tailMutation = Array(records.dropLast())
        tailMutation.append(
            LaunchRecord(
                id: "launch-39",
                prefixId: PrefixIdentifier.steamShared,
                commandKind: "launchSteam",
                startedAt: records[39].startedAt,
                exitCode: 999,
                hostAppSessionID: "other-session",
                environmentGenerationID: "generation"
            )
        )
        XCTAssertEqual(
            SteamLaunchRecordLookup.newestFirstStateFingerprint(from: records),
            SteamLaunchRecordLookup.newestFirstStateFingerprint(from: tailMutation)
        )
        XCTAssertEqual(
            readinessFingerprint,
            SteamLaunchRecordLookup.newestFirstReadinessFingerprint(
                from: tailMutation,
                environmentIdentity: identity,
                currentAppSessionID: "current-session"
            )
        )
        XCTAssertEqual(
            readinessFingerprint,
            SteamLaunchRecordLookup.newestFirstReadinessFingerprint(
                from: Array(records.dropLast()),
                environmentIdentity: identity,
                currentAppSessionID: "current-session"
            )
        )
        XCTAssertNotEqual(
            readinessFingerprint,
            SteamLaunchRecordLookup.newestFirstReadinessFingerprint(
                from: records.filter { $0.id != records[3].id },
                environmentIdentity: identity,
                currentAppSessionID: "current-session"
            )
        )
        XCTAssertTrue(
            SteamLaunchRecordLookup.latestSteamLaunchRecordFromNewestFirst(
                records,
                environmentGenerationID: "generation",
                currentAppSessionID: "current-session"
            ) === records[7]
        )
        XCTAssertTrue(
            SteamLaunchRecordLookup.latestSteamLaunchRecordFromNewestFirst(
                records,
                environmentGenerationID: "generation",
                currentAppSessionID: "missing-session"
            ) === records[0]
        )
    }

    func testMainWindowOwnsInitialSetupWorkflowSynchronization() throws {
        let root = try projectSource("Sources/ForgePlay/UI/RootView.swift")
        let dashboard = try projectSource("Sources/ForgePlay/UI/DashboardView.swift")
        let setup = try projectSource("Sources/ForgePlay/UI/SetupView.swift")
        let settings = try projectSource("Sources/ForgePlay/UI/SettingsView.swift")

        XCTAssertTrue(root.contains("SetupView(performsInitialWorkflowRefresh: false)"))
        XCTAssertTrue(root.contains("SettingsView(performsInitialWorkflowRefresh: false)"))
        XCTAssertFalse(dashboard.contains("private func refreshSetupReadiness()"))
        XCTAssertTrue(setup.contains("init(performsInitialWorkflowRefresh: Bool = true)"))
        XCTAssertTrue(setup.contains("await refreshChecksAndProgress()"))
        XCTAssertTrue(settings.contains("var performsInitialWorkflowRefresh = true"))
        XCTAssertTrue(root.contains(".onChange(of: setupReadinessObservationKey)"))
        XCTAssertTrue(setup.contains(".onChange(of: setupReadinessObservationKey)"))
        XCTAssertTrue(settings.contains(".onChange(of: setupReadinessObservationKey)"))
        XCTAssertFalse(setup.contains("forceRefresh"))
        XCTAssertFalse(settings.contains("forceRefresh"))
    }

    func testSetupWorkflowRefreshUsesImmutableInputsAndExactCommitTicket() throws {
        let source = try projectSource("Sources/ForgePlay/App/AppServices.swift")
        let refreshStart = try XCTUnwrap(
            source.range(of: "    func refreshSetupWorkflow(")?.lowerBound
        )
        let preparationStart = try XCTUnwrap(
            source.range(of: "    func prepareManagedStorageOnce(", range: refreshStart..<source.endIndex)?
                .lowerBound
        )
        let refresh = String(source[refreshStart..<preparationStart])

        XCTAssertFalse(refresh.contains("forceRefresh"))
        XCTAssertFalse(refresh.contains("completedSetupWorkflowRefresh"))
        XCTAssertTrue(refresh.contains("activeAttempt.key == key"))
        XCTAssertTrue(refresh.contains("setupWorkflowRefreshAttemptGate.issue()"))
        XCTAssertTrue(refresh.contains("setupWorkflowRefreshAttemptGate.begin(ticket)"))
        XCTAssertTrue(refresh.contains("setupWorkflowRefreshAttemptGate.permitsCommit(ticket)"))
        XCTAssertTrue(refresh.contains("SetupWorkflowRefreshWaiterRegistry"))
        XCTAssertTrue(refresh.contains("cancelSetupWorkflowRefreshAttemptAfterFinalWaiter("))
        XCTAssertTrue(refresh.contains("completeSetupWorkflowRefreshAttempt("))
        XCTAssertFalse(refresh.contains("attempt.task.value"))
        let coordinatorRefresh = try XCTUnwrap(
            refresh.range(of: "self.setupWorkflowCoordinator.computeRefresh(")?
                .lowerBound
        )
        let postCoordinatorCancellation = try XCTUnwrap(
            refresh.range(
                of: "try Task.checkCancellation()",
                range: coordinatorRefresh..<refresh.endIndex
            )?.lowerBound
        )
        let coordinatorInvocation = String(
            refresh[coordinatorRefresh..<postCoordinatorCancellation]
        )
        XCTAssertTrue(coordinatorInvocation.contains("runtimeExecutable: runtimeExecutable"))
        XCTAssertTrue(
            coordinatorInvocation.contains(
                "rendererPolicySelection: rendererPolicySelection"
            )
        )
        XCTAssertTrue(
            coordinatorInvocation.contains("videoMemorySelection: videoMemorySelection")
        )
        XCTAssertGreaterThanOrEqual(
            refresh.components(separatedBy: "try self.validateSetupWorkflowObservation(")
                .count - 1,
            2
        )
        XCTAssertFalse(coordinatorInvocation.contains("appState."))
        XCTAssertGreaterThanOrEqual(
            refresh.components(separatedBy: "try Task.checkCancellation()").count - 1,
            3
        )
        let exactCommit = try XCTUnwrap(
            refresh.range(of: "try self.commitSetupWorkflowRefresh(")?
                .lowerBound
        )
        XCTAssertLessThan(coordinatorRefresh, exactCommit)

        let finalCancellationStart = try XCTUnwrap(
            refresh.range(
                of: "    private func cancelSetupWorkflowRefreshAttemptAfterFinalWaiter("
            )?.lowerBound
        )
        let completionStart = try XCTUnwrap(
            refresh.range(
                of: "    private func completeSetupWorkflowRefreshAttempt(",
                range: finalCancellationStart..<refresh.endIndex
            )?.lowerBound
        )
        let finalCancellation = String(refresh[finalCancellationStart..<completionStart])
        let invalidateAttempt = try XCTUnwrap(
            finalCancellation.range(of: "activeSetupWorkflowRefreshAttempt = nil")?.lowerBound
        )
        let invalidateCommit = try XCTUnwrap(
            finalCancellation.range(of: "setupWorkflowRefreshAttemptGate.finish(ticket)")?.lowerBound
        )
        let cancelTask = try XCTUnwrap(
            finalCancellation.range(of: "activeAttempt.task.cancel()")?.lowerBound
        )
        XCTAssertLessThan(invalidateAttempt, invalidateCommit)
        XCTAssertLessThan(invalidateCommit, cancelTask)
    }

    func testStableManagedStorageStartupDoesNotRunRootChangeShutdown() throws {
        let source = try projectSource("Sources/ForgePlay/App/AppServices.swift")
        let preparationStart = try XCTUnwrap(
            source.range(of: "    func prepareManagedStorageOnce(")?.lowerBound
        )
        let migrationStart = try XCTUnwrap(
            source.range(
                of: "    func migratePersistedLegacyManagedStorage(",
                range: preparationStart..<source.endIndex
            )?.lowerBound
        )
        let preparation = String(source[preparationStart..<migrationStart])
        let legacyBranchStart = try XCTUnwrap(
            preparation.range(of: "if let legacyRoot = request.legacySource")?.lowerBound
        )
        let activationStart = try XCTUnwrap(
            preparation.range(of: "var activation = try await self.managedStorageService.activate")?
                .lowerBound
        )
        let legacyTransition = String(preparation[legacyBranchStart..<activationStart])

        XCTAssertEqual(
            legacyTransition.components(
                separatedBy: "shutdownSteamProcessesBeforeRootChange("
            ).count - 1,
            2
        )
        XCTAssertTrue(
            legacyTransition.contains(
                "steamPrefixService.claimRuntimeOwnership("
            )
        )
        XCTAssertFalse(
            String(preparation[activationStart...]).contains(
                "shutdownSteamProcessesBeforeRootChange("
            )
        )
    }

    func testSetupWorkflowCoordinatorIsComputeOnly() throws {
        let source = try projectSource(
            "Sources/ForgePlay/Services/SetupWorkflowCoordinator.swift"
        )

        XCTAssertTrue(source.contains("func computeRefresh("))
        XCTAssertTrue(source.contains("func computeReadiness("))
        XCTAssertFalse(source.contains("AppState"))
        XCTAssertFalse(source.contains("updateSetupStage"))
        XCTAssertFalse(source.contains("latestChecks"))
    }

    func testInternalSupersessionRetriesWhileOuterCancellationStops() throws {
        XCTAssertTrue(
            SetupWorkflowRefreshRetryPolicy.shouldRetryAfterSupersession(
                outerTaskIsCancelled: false
            )
        )
        XCTAssertFalse(
            SetupWorkflowRefreshRetryPolicy.shouldRetryAfterSupersession(
                outerTaskIsCancelled: true
            )
        )

        let root = try projectSource("Sources/ForgePlay/UI/RootView.swift")
        let settings = try projectSource("Sources/ForgePlay/UI/SettingsView.swift")
        XCTAssertTrue(root.contains("catch SetupWorkflowRefreshControlError.superseded"))
        XCTAssertTrue(root.contains("await Task.yield()"))
        XCTAssertTrue(root.contains("catch is CancellationError"))
        XCTAssertTrue(root.contains("try Task.checkCancellation()"))
        XCTAssertTrue(settings.contains("try await refreshSetupWorkflowUntilCurrent()"))
        let refresh = try XCTUnwrap(
            settings.range(of: "try await refreshSetupWorkflowUntilCurrent()")?.lowerBound
        )
        let load = try XCTUnwrap(
            settings.range(of: "loadSettings()", range: refresh..<settings.endIndex)?.lowerBound
        )
        XCTAssertLessThan(refresh, load)
        XCTAssertTrue(settings.contains("catch SetupWorkflowRefreshControlError.superseded"))
    }

    func testSteamLaunchObserversUseOneRowBoundWhileRepositoryOwnsContinuity() throws {
        for path in [
            "Sources/ForgePlay/UI/RootView.swift",
            "Sources/ForgePlay/UI/DashboardView.swift",
            "Sources/ForgePlay/UI/SetupView.swift",
            "Sources/ForgePlay/UI/SettingsView.swift",
            "Sources/ForgePlay/UI/SteamLaunchView.swift"
        ] {
            let source = try projectSource(path)
            let start = try XCTUnwrap(
                source.range(of: "var launchDescriptor = FetchDescriptor<LaunchRecord>(")?.lowerBound,
                path
            )
            let end = try XCTUnwrap(
                source.range(
                    of: "_launchRecords = Query(launchDescriptor)",
                    range: start..<source.endIndex
                )?.upperBound,
                path
            )
            let query = String(source[start..<end])

            XCTAssertTrue(query.contains("$0.commandKind == \"launchSteam\""), path)
            XCTAssertTrue(query.contains("$0.prefixId == \"prefix-steam-shared\""), path)
            XCTAssertTrue(
                query.contains(
                    "SortDescriptor(\\LaunchRecord.startedAt, order: .reverse)"
                ),
                path
            )
            XCTAssertTrue(query.contains("launchDescriptor.fetchLimit = 1"), path)
        }

        let repository = try projectSource(
            "Sources/ForgePlay/Services/SteamPrefixState.swift"
        )
        XCTAssertTrue(repository.contains("struct SteamLaunchReadinessRepository"))
        XCTAssertTrue(repository.contains("requiredContinuitySessionCount = 2"))
        XCTAssertTrue(repository.contains("excludingAppSessionID: firstSessionID"))
        XCTAssertTrue(repository.contains("$0.hostAppSessionID != excludingAppSessionID"))
        XCTAssertTrue(repository.contains("descriptor.fetchLimit = 1"))
        XCTAssertTrue(repository.contains("@ModelActor\nactor SteamLaunchHistoryMaintenanceWorker"))
        XCTAssertTrue(repository.contains("private var pendingRequest: Request?"))
        XCTAssertTrue(repository.contains("$0.hostAppSessionID != currentAppSessionID"))
    }

    func testSteamLaunchHistoryWorkerIsConstructedOutsideMainActor() throws {
        let source = try projectSource(
            "Sources/ForgePlay/Services/SteamPrefixState.swift"
        )
        let schedulerStart = try XCTUnwrap(
            source.range(
                of: "final class SteamLaunchHistoryMaintenanceScheduler"
            )?.lowerBound
        )
        let resolverStart = try XCTUnwrap(
            source.range(
                of: "final class SteamPrefixReadinessResolver",
                range: schedulerStart..<source.endIndex
            )?.lowerBound
        )
        let scheduler = String(source[schedulerStart..<resolverStart])
        let detachedTask = try XCTUnwrap(
            scheduler.range(of: "Task.detached(priority: .utility)")?.lowerBound
        )
        let workerConstruction = try XCTUnwrap(
            scheduler.range(
                of: "let worker = SteamLaunchHistoryMaintenanceWorker("
            )?.lowerBound
        )

        XCTAssertLessThan(detachedTask, workerConstruction)
        XCTAssertFalse(
            scheduler[..<detachedTask].contains(
                "SteamLaunchHistoryMaintenanceWorker("
            )
        )
        XCTAssertTrue(scheduler.contains("private struct Request: Sendable"))
        XCTAssertTrue(scheduler.contains("await self?.finish("))
    }

    func testSetupRefreshCancellationIsNotPublishedAsUIError() throws {
        for path in [
            "Sources/ForgePlay/UI/DashboardView.swift",
            "Sources/ForgePlay/UI/SetupView.swift",
            "Sources/ForgePlay/UI/SettingsView.swift"
        ] {
            let source = try projectSource(path)
            XCTAssertTrue(source.contains("catch is CancellationError"), path)
        }
        let settings = try projectSource("Sources/ForgePlay/UI/SettingsView.swift")
        XCTAssertGreaterThanOrEqual(
            settings.components(separatedBy: "catch is CancellationError").count - 1,
            2
        )
    }

    func testModelContainerBootstrapIsAsynchronousAndStartsExactlyOnce() throws {
        let source = try projectSource("Sources/ForgePlay/ForgePlayApp.swift")
        let bootstrapStart = try XCTUnwrap(
            source.range(of: "final class ForgePlayModelContainerBootstrap")?.lowerBound
        )
        let appStart = try XCTUnwrap(
            source.range(of: "@main\nstruct ForgePlayApp: App")?.lowerBound
        )
        let bootstrap = String(source[bootstrapStart..<appStart])

        XCTAssertTrue(bootstrap.contains("private var didStart = false"))
        XCTAssertTrue(bootstrap.contains("guard !didStart else { return }"))
        XCTAssertTrue(bootstrap.contains("private var currentAttemptToken: UUID?"))
        XCTAssertTrue(bootstrap.contains("func retryAfterFailure() -> Bool"))
        XCTAssertTrue(bootstrap.contains("typealias Factory = @Sendable () async throws -> ModelContainer"))
        XCTAssertTrue(bootstrap.contains("Task { @MainActor [weak self] in"))
        XCTAssertTrue(bootstrap.contains("self.result = attemptResult"))
        XCTAssertTrue(bootstrap.contains("self.completedPublicationCount += 1"))
        XCTAssertFalse(bootstrap.contains("Task.sleep"))
        XCTAssertTrue(source.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(source.contains("nonisolated static func makeModelContainer("))
    }

    @MainActor
    func testRepeatedBootstrapStartPublishesExactlyOneFactoryResult() async throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let gate = StartupModelContainerFactoryGate()
        let bootstrap = ForgePlayModelContainerBootstrap {
            await gate.makeContainer()
        }

        for _ in 0..<12 {
            bootstrap.startIfNeeded()
        }
        let didStart = await waitForFactoryCalls(1, gate: gate)
        XCTAssertTrue(didStart)

        await gate.complete(with: container)
        let didPublish = await waitForPublication(bootstrap)
        XCTAssertTrue(didPublish)
        let initialCallCount = await gate.observedCallCount()
        XCTAssertEqual(initialCallCount, 1)
        XCTAssertEqual(bootstrap.completedPublicationCount, 1)
        guard case .success(let publishedContainer)? = bootstrap.result else {
            XCTFail("Expected one successful bootstrap publication")
            return
        }
        XCTAssertTrue(publishedContainer === container)

        for _ in 0..<12 {
            bootstrap.startIfNeeded()
        }
        await Task.yield()
        let finalCallCount = await gate.observedCallCount()
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertEqual(bootstrap.completedPublicationCount, 1)
    }

    @MainActor
    func testFailedBootstrapRetriesOnceAndPublishesSuccess() async throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let gate = StartupModelContainerRetryGate()
        let bootstrap = ForgePlayModelContainerBootstrap {
            try await gate.makeContainer()
        }

        bootstrap.startIfNeeded()
        let didStartFirstAttempt = await waitForRetryFactoryCalls(1, gate: gate)
        XCTAssertTrue(didStartFirstAttempt)
        await gate.complete(attempt: 1, with: .failure)
        let didPublishFailure = await waitForPublicationCount(1, bootstrap: bootstrap)
        XCTAssertTrue(didPublishFailure)
        guard case .failure? = bootstrap.result else {
            return XCTFail("Expected the first attempt to publish its failure")
        }

        XCTAssertTrue(bootstrap.retryAfterFailure())
        XCTAssertNil(bootstrap.result)
        let didStartRetry = await waitForRetryFactoryCalls(2, gate: gate)
        XCTAssertTrue(didStartRetry)
        await gate.complete(attempt: 2, with: .success(container))
        let didPublishSuccess = await waitForPublicationCount(2, bootstrap: bootstrap)
        XCTAssertTrue(didPublishSuccess)

        guard case .success(let publishedContainer)? = bootstrap.result else {
            return XCTFail("Expected retry success to replace the failure immediately")
        }
        XCTAssertTrue(publishedContainer === container)
        XCTAssertEqual(bootstrap.startedAttemptCount, 2)
        XCTAssertEqual(bootstrap.completedPublicationCount, 2)
    }

    @MainActor
    func testRepeatedRetryRequestsRemainSingleFlight() async throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let gate = StartupModelContainerRetryGate()
        let bootstrap = ForgePlayModelContainerBootstrap {
            try await gate.makeContainer()
        }

        bootstrap.startIfNeeded()
        let didStartFirstAttempt = await waitForRetryFactoryCalls(1, gate: gate)
        XCTAssertTrue(didStartFirstAttempt)
        await gate.complete(attempt: 1, with: .failure)
        let didPublishFailure = await waitForPublicationCount(1, bootstrap: bootstrap)
        XCTAssertTrue(didPublishFailure)

        XCTAssertTrue(bootstrap.retryAfterFailure())
        for _ in 0..<12 {
            XCTAssertFalse(bootstrap.retryAfterFailure())
        }
        let didStartRetry = await waitForRetryFactoryCalls(2, gate: gate)
        XCTAssertTrue(didStartRetry)
        XCTAssertEqual(bootstrap.startedAttemptCount, 2)

        await gate.complete(attempt: 2, with: .success(container))
        let didPublishSuccess = await waitForPublicationCount(2, bootstrap: bootstrap)
        XCTAssertTrue(didPublishSuccess)
        let callCount = await gate.observedCallCount()
        XCTAssertEqual(callCount, 2)
    }

    @MainActor
    func testCancelledOldAttemptCannotPublishAfterRearmedAttempt() async throws {
        let oldContainer = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let currentContainer = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let gate = StartupModelContainerRetryGate()
        let bootstrap = ForgePlayModelContainerBootstrap {
            try await gate.makeContainer()
        }

        bootstrap.startIfNeeded()
        let didStartOldAttempt = await waitForRetryFactoryCalls(1, gate: gate)
        XCTAssertTrue(didStartOldAttempt)
        bootstrap.cancel()
        bootstrap.startIfNeeded()
        let didStartCurrentAttempt = await waitForRetryFactoryCalls(2, gate: gate)
        XCTAssertTrue(didStartCurrentAttempt)

        await gate.complete(attempt: 2, with: .success(currentContainer))
        let didPublishCurrentAttempt = await waitForPublicationCount(1, bootstrap: bootstrap)
        XCTAssertTrue(didPublishCurrentAttempt)
        await gate.complete(attempt: 1, with: .success(oldContainer))
        let didReturnBothAttempts = await waitForRetryFactoryReturns(2, gate: gate)
        XCTAssertTrue(didReturnBothAttempts)
        await yieldToScheduledTasks()

        guard case .success(let publishedContainer)? = bootstrap.result else {
            return XCTFail("Expected the rearmed attempt to remain published")
        }
        XCTAssertTrue(publishedContainer === currentContainer)
        XCTAssertEqual(bootstrap.startedAttemptCount, 2)
        XCTAssertEqual(bootstrap.completedPublicationCount, 1)
    }

    func testStartupFailureViewsExposeExplicitLocalizedRetryWithoutDelay() throws {
        let source = try projectSource("Sources/ForgePlay/ForgePlayApp.swift")
        let recoveryStart = try XCTUnwrap(
            source.range(of: "private func startupFailureRecoveryView(")?.lowerBound
        )
        let factoryStart = try XCTUnwrap(
            source.range(of: "private static func modelContainerFactory()", range: recoveryStart..<source.endIndex)?
                .lowerBound
        )
        let recovery = String(source[recoveryStart..<factoryStart])

        XCTAssertTrue(recovery.contains("Button(appState.localized(\"다시 시도\"))"))
        XCTAssertTrue(recovery.contains("modelContainerBootstrap.retryAfterFailure()"))
        XCTAssertTrue(recovery.contains("ForgePlayStartupFailureRecoveryLayout {"))
        XCTAssertTrue(recovery.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(recovery.contains("ZStack(alignment: .bottom)"))
        XCTAssertFalse(recovery.contains("Task.sleep"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "startupFailureRecoveryView(").count - 1,
            3
        )
    }

    func testStartupFailureRecoveryLayoutReservesReachableNonOverlappingActionRegion() {
        let settingsBounds = CGRect(x: 17, y: 23, width: 520, height: 420)
        let measuredActionHeights: [CGFloat] = [44, 88, 168, 640]

        for measuredActionHeight in measuredActionHeights {
            let partition = ForgePlayStartupFailureRecoveryLayout.partition(
                in: settingsBounds,
                measuredActionHeight: measuredActionHeight
            )

            XCTAssertEqual(partition.failureFrame.minX, settingsBounds.minX)
            XCTAssertEqual(partition.failureFrame.minY, settingsBounds.minY)
            XCTAssertEqual(partition.failureFrame.width, settingsBounds.width)
            XCTAssertEqual(partition.failureFrame.maxY, partition.actionFrame.minY)
            XCTAssertEqual(partition.actionFrame.minX, settingsBounds.minX)
            XCTAssertEqual(partition.actionFrame.maxY, settingsBounds.maxY)
            XCTAssertEqual(partition.actionFrame.width, settingsBounds.width)
            XCTAssertEqual(
                partition.failureFrame.intersection(partition.actionFrame).height,
                0
            )
            XCTAssertGreaterThan(partition.actionFrame.height, 0)
            XCTAssertLessThanOrEqual(partition.actionFrame.height, settingsBounds.height)
        }

        let accessibilityPartition = ForgePlayStartupFailureRecoveryLayout.partition(
            in: settingsBounds,
            measuredActionHeight: 168
        )
        XCTAssertEqual(accessibilityPartition.actionFrame.height, 168)
        XCTAssertEqual(accessibilityPartition.failureFrame.height, 252)
    }

    @MainActor
    func testCancelledBootstrapDoesNotPublishLateFactoryResult() async throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let gate = StartupModelContainerFactoryGate()
        let bootstrap = ForgePlayModelContainerBootstrap {
            await gate.makeContainer()
        }

        bootstrap.startIfNeeded()
        let didStart = await waitForFactoryCalls(1, gate: gate)
        XCTAssertTrue(didStart)
        bootstrap.cancel()
        await gate.complete(with: container)
        let didReturn = await waitForFactoryReturns(1, gate: gate)
        XCTAssertTrue(didReturn)
        await yieldToScheduledTasks()

        XCTAssertNil(bootstrap.result)
        XCTAssertEqual(bootstrap.completedPublicationCount, 0)
    }

    @MainActor
    func testDeallocatedBootstrapCannotPublishLateFactoryResult() async throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let gate = StartupModelContainerFactoryGate()
        var bootstrap: ForgePlayModelContainerBootstrap? = ForgePlayModelContainerBootstrap {
            await gate.makeContainer()
        }
        let weakBootstrap = StartupWeakReferenceBox(bootstrap)

        bootstrap?.startIfNeeded()
        let didStart = await waitForFactoryCalls(1, gate: gate)
        XCTAssertTrue(didStart)
        bootstrap = nil
        XCTAssertNil(weakBootstrap.value)

        await gate.complete(with: container)
        let didReturn = await waitForFactoryReturns(1, gate: gate)
        XCTAssertTrue(didReturn)
        await yieldToScheduledTasks()
        XCTAssertNil(weakBootstrap.value)
    }

    func testInitialSceneRendersLoadingStateBeforeContainerCompletes() throws {
        let source = try projectSource("Sources/ForgePlay/ForgePlayApp.swift")
        let initializerStart = try XCTUnwrap(source.range(of: "    init() {")?.lowerBound)
        let bodyStart = try XCTUnwrap(source.range(of: "\n    var body: some Scene {")?.lowerBound)
        let initializer = String(source[initializerStart..<bodyStart])

        XCTAssertTrue(initializer.contains("ForgePlayModelContainerBootstrap("))
        XCTAssertFalse(initializer.contains("try Self.makeModelContainer("))
        XCTAssertFalse(initializer.contains("Result {"))
        XCTAssertTrue(source.contains("switch modelContainerBootstrap.result"))
        XCTAssertTrue(source.contains("case .none:"))
        XCTAssertTrue(source.contains("ForgePlayLaunchSplashView()"))
        XCTAssertTrue(source.contains("modelContainerBootstrap.startIfNeeded()"))
        XCTAssertTrue(source.contains("appState.localized(\"실행 준비 중…\")"))

        let rootSource = try projectSource("Sources/ForgePlay/UI/RootView.swift")
        XCTAssertTrue(rootSource.contains("if startupPresentation.showsBrandedLoading"))
        XCTAssertTrue(rootSource.contains("ForgePlayLaunchSplashView()"))
        XCTAssertTrue(rootSource.contains("transitioned(for: .succeeded)"))
        XCTAssertTrue(rootSource.contains(".requiresUserIntervention : .failed"))
    }

    func testRootLogCleanupCancellationStopsOwnedWorkAndSuppressesLateNotice() throws {
        let source = try projectSource("Sources/ForgePlay/UI/RootView.swift")
        let cleanupStart = try XCTUnwrap(
            source.range(of: "private func scheduleAutomaticLogCleanup")?.lowerBound
        )
        let debugStart = try XCTUnwrap(
            source.range(of: "\n    #if DEBUG", range: cleanupStart..<source.endIndex)?
                .lowerBound
        )
        let cleanup = String(source[cleanupStart..<debugStart])

        XCTAssertTrue(cleanup.contains("withTaskCancellationHandler"))
        XCTAssertTrue(cleanup.contains("onCancel:"))
        XCTAssertTrue(cleanup.contains("cleanupTask.cancel()"))
        XCTAssertTrue(cleanup.contains("guard !Task.isCancelled else { return }"))
        XCTAssertTrue(source.contains("automaticLogCleanupTask?.cancel()"))
    }

    func testPersistentStoreUsesNonFollowingValidationAndRetainsCreationLease() throws {
        let source = try projectSource("Sources/ForgePlay/ForgePlayApp.swift")

        XCTAssertTrue(source.contains("let preparedStore = try preparePersistentStore("))
        XCTAssertTrue(source.contains("defer { preparedStore.migrationLease?.release() }"))
        XCTAssertTrue(source.contains("validateStoreAndSidecarsIfPresent(at: storeURL)"))
        XCTAssertTrue(source.contains("for suffix in [\"-wal\", \"-shm\"]"))
        XCTAssertTrue(source.contains("Darwin.lstat(url.path, &status)"))
        XCTAssertTrue(source.contains("O_RDONLY | O_CLOEXEC | O_NOFOLLOW"))
        XCTAssertTrue(source.contains("descriptorStatus.st_nlink == 1"))
        XCTAssertTrue(source.contains("descriptorStatus.st_ino == nonFollowingStatus.st_ino"))
    }

    func testPersistentStoreRejectsUnsafeMainEntryKinds() throws {
        for entryKind in UnsafeStoreEntryKind.allCases {
            try withTemporaryStorePath { baseURL, storeURL in
                try entryKind.install(at: storeURL, baseURL: baseURL)
                XCTAssertThrowsError(
                    try ForgePlayApp.preparePersistentStoreURL(
                        applicationSupportDirectory: baseURL
                    ),
                    "Expected \(entryKind) main store to be rejected"
                )
            }
        }
    }

    func testPersistentStoreRejectsUnsafeSQLiteSidecars() throws {
        for suffix in ["-wal", "-shm"] {
            try withTemporaryStorePath { baseURL, storeURL in
                try Data("sqlite-main".utf8).write(to: storeURL)
                let sidecarURL = URL(fileURLWithPath: storeURL.path + suffix)
                try FileManager.default.createSymbolicLink(
                    at: sidecarURL,
                    withDestinationURL: baseURL.appending(path: "missing-sidecar-target")
                )
                XCTAssertThrowsError(
                    try ForgePlayApp.preparePersistentStoreURL(
                        applicationSupportDirectory: baseURL
                    ),
                    "Expected unsafe \(suffix) sidecar to be rejected"
                )
            }
        }
    }

    func testPersistentStoreAcceptsRegularSingleLinkSQLiteSidecars() throws {
        try withTemporaryStorePath { baseURL, storeURL in
            try Data("sqlite-main".utf8).write(to: storeURL)
            try Data("sqlite-wal".utf8).write(
                to: URL(fileURLWithPath: storeURL.path + "-wal")
            )
            try Data("sqlite-shm".utf8).write(
                to: URL(fileURLWithPath: storeURL.path + "-shm")
            )

            let preparedURL = try ForgePlayApp.preparePersistentStoreURL(
                applicationSupportDirectory: baseURL
            )
            XCTAssertEqual(preparedURL, storeURL)
        }
    }

    func testMainWindowFontActivationYieldsBeforeStarting() throws {
        let source = try projectSource("Sources/ForgePlay/ForgePlayApp.swift")
        let mainWindowStart = try XCTUnwrap(
            source.range(of: "WindowGroup(id: ForgePlaySceneID.main) {")?.lowerBound
        )
        let settingsStart = try XCTUnwrap(
            source.range(of: "\n        Settings {")?.lowerBound
        )
        let mainWindow = String(source[mainWindowStart..<settingsStart])
        let yieldPosition = try XCTUnwrap(mainWindow.range(of: "await Task.yield()")?.lowerBound)
        let activationPosition = try XCTUnwrap(
            mainWindow.range(of: "await services.activateFontCompatibilityPack(")?.lowerBound
        )

        XCTAssertLessThan(yieldPosition, activationPosition)

        let settingsWindow = String(source[settingsStart...])
        XCTAssertTrue(settingsWindow.contains("await services.activateFontCompatibilityPack("))
    }

    func testPrimaryStatusViewsUsePublishedSnapshotsInsteadOfSynchronousInspection() throws {
        let paths = [
            "Sources/ForgePlay/UI/DashboardView.swift",
            "Sources/ForgePlay/UI/SetupView.swift",
            "Sources/ForgePlay/UI/SettingsView.swift"
        ]

        for path in paths {
            let source = try projectSource(path)
            XCTAssertTrue(source.contains("appState.setupReadiness"), path)
            XCTAssertTrue(source.contains("appState.latestChecks"), path)
            XCTAssertFalse(source.contains("inspectRuntimeCapability("), path)
            XCTAssertFalse(source.contains("inspectSteamClientCompatibility("), path)
        }

        let setupSource = try projectSource("Sources/ForgePlay/UI/SetupView.swift")
        XCTAssertFalse(setupSource.contains("validateWindowsSteamClientLaunchSupport("))
        XCTAssertTrue(setupSource.contains("services.prepareSteamPrefix("))
        XCTAssertTrue(setupSource.contains("refreshSetupWorkflow("))
    }

    private func projectSource(_ path: String) throws -> String {
        try String(contentsOf: projectRoot().appending(path: path), encoding: .utf8)
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appending(path: "project.yml").path) {
                return url
            }
        }
        throw XCTSkip("Project root not found")
    }

    private func withTemporaryStorePath(
        _ body: (URL, URL) throws -> Void
    ) throws {
        let baseURL = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlay-StartupPerformanceTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let storeDirectory = baseURL.appending(
            path: ForgePlayApp.applicationSupportDirectoryName,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: baseURL) }
        try body(
            baseURL,
            storeDirectory.appending(
                path: ForgePlayApp.persistentStoreFileName,
                directoryHint: .notDirectory
            )
        )
    }

    @MainActor
    private func waitForFactoryCalls(
        _ expectedCount: Int,
        gate: StartupModelContainerFactoryGate
    ) async -> Bool {
        for _ in 0..<2_000 {
            if await gate.observedCallCount() == expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }

    @MainActor
    private func waitForFactoryReturns(
        _ expectedCount: Int,
        gate: StartupModelContainerFactoryGate
    ) async -> Bool {
        for _ in 0..<2_000 {
            if await gate.observedReturnCount() == expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }

    @MainActor
    private func waitForPublication(
        _ bootstrap: ForgePlayModelContainerBootstrap
    ) async -> Bool {
        for _ in 0..<2_000 {
            if bootstrap.result != nil {
                return true
            }
            await Task.yield()
        }
        return false
    }

    @MainActor
    private func waitForPublicationCount(
        _ expectedCount: Int,
        bootstrap: ForgePlayModelContainerBootstrap
    ) async -> Bool {
        for _ in 0..<2_000 {
            if bootstrap.completedPublicationCount == expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }

    @MainActor
    private func waitForRetryFactoryCalls(
        _ expectedCount: Int,
        gate: StartupModelContainerRetryGate
    ) async -> Bool {
        for _ in 0..<2_000 {
            if await gate.observedCallCount() == expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }

    @MainActor
    private func waitForRetryFactoryReturns(
        _ expectedCount: Int,
        gate: StartupModelContainerRetryGate
    ) async -> Bool {
        for _ in 0..<2_000 {
            if await gate.observedReturnCount() == expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }

    @MainActor
    private func yieldToScheduledTasks() async {
        for _ in 0..<32 {
            await Task.yield()
        }
    }
}

private enum SetupWorkflowWaiterTestOutcome: Equatable, Sendable {
    case value(String)
    case cancelled
    case failed
}

private enum SetupWorkflowWaiterTestError: Error {
    case registrationDidNotReachExpectedCount
}

@MainActor
private final class SetupWorkflowFinalWaiterCancellationProbe {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

@MainActor
private func setupWorkflowWaiterOutcome(
    registry: SetupWorkflowRefreshWaiterRegistry<String>,
    cancellationProbe: SetupWorkflowFinalWaiterCancellationProbe
) async -> SetupWorkflowWaiterTestOutcome {
    do {
        return .value(
            try await registry.wait {
                cancellationProbe.record()
            }
        )
    } catch is CancellationError {
        return .cancelled
    } catch {
        return .failed
    }
}

@MainActor
private func waitForSetupWorkflowWaiterCount(
    _ expectedCount: Int,
    registry: SetupWorkflowRefreshWaiterRegistry<String>
) async throws {
    for _ in 0..<2_000 {
        if registry.waiterCount == expectedCount {
            return
        }
        await Task.yield()
    }
    throw SetupWorkflowWaiterTestError.registrationDidNotReachExpectedCount
}

private enum UnsafeStoreEntryKind: String, CaseIterable, CustomStringConvertible {
    case danglingSymbolicLink
    case symbolicLink
    case directory
    case fifo
    case hardLink

    var description: String { rawValue }

    func install(at storeURL: URL, baseURL: URL) throws {
        switch self {
        case .danglingSymbolicLink:
            try FileManager.default.createSymbolicLink(
                at: storeURL,
                withDestinationURL: baseURL.appending(path: "missing-store-target")
            )
        case .symbolicLink:
            let targetURL = baseURL.appending(path: "store-target")
            try Data("target".utf8).write(to: targetURL)
            try FileManager.default.createSymbolicLink(
                at: storeURL,
                withDestinationURL: targetURL
            )
        case .directory:
            try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: false)
        case .fifo:
            guard Darwin.mkfifo(storeURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        case .hardLink:
            let targetURL = baseURL.appending(path: "hard-link-target")
            try Data("target".utf8).write(to: targetURL)
            try FileManager.default.linkItem(at: targetURL, to: storeURL)
        }
    }
}

private final class StartupWeakReferenceBox<Object: AnyObject> {
    weak var value: Object?

    init(_ value: Object?) {
        self.value = value
    }
}

private actor StartupModelContainerFactoryGate {
    private var callCount = 0
    private var returnCount = 0
    private var continuation: CheckedContinuation<ModelContainer, Never>?
    private var pendingContainer: ModelContainer?

    func makeContainer() async -> ModelContainer {
        callCount += 1
        let container: ModelContainer
        if let pendingContainer {
            self.pendingContainer = nil
            container = pendingContainer
        } else {
            container = await withCheckedContinuation { continuation in
                precondition(self.continuation == nil)
                self.continuation = continuation
            }
        }
        returnCount += 1
        return container
    }

    func complete(with container: ModelContainer) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: container)
        } else {
            pendingContainer = container
        }
    }

    func observedCallCount() -> Int {
        callCount
    }

    func observedReturnCount() -> Int {
        returnCount
    }
}

private enum StartupModelContainerRetryOutcome: Sendable {
    case success(ModelContainer)
    case failure
}

private enum StartupModelContainerRetryFailure: Error {
    case expected
}

private actor StartupModelContainerRetryGate {
    private var callCount = 0
    private var returnCount = 0
    private var continuations:
        [Int: CheckedContinuation<StartupModelContainerRetryOutcome, Never>] = [:]
    private var pendingOutcomes: [Int: StartupModelContainerRetryOutcome] = [:]

    func makeContainer() async throws -> ModelContainer {
        callCount += 1
        let attempt = callCount
        let outcome: StartupModelContainerRetryOutcome
        if let pendingOutcome = pendingOutcomes.removeValue(forKey: attempt) {
            outcome = pendingOutcome
        } else {
            outcome = await withCheckedContinuation { continuation in
                continuations[attempt] = continuation
            }
        }
        returnCount += 1
        switch outcome {
        case .success(let container):
            return container
        case .failure:
            throw StartupModelContainerRetryFailure.expected
        }
    }

    func complete(
        attempt: Int,
        with outcome: StartupModelContainerRetryOutcome
    ) {
        if let continuation = continuations.removeValue(forKey: attempt) {
            continuation.resume(returning: outcome)
        } else {
            pendingOutcomes[attempt] = outcome
        }
    }

    func observedCallCount() -> Int {
        callCount
    }

    func observedReturnCount() -> Int {
        returnCount
    }
}
