import Foundation
import XCTest
@testable import ForgePlay

final class SteamCompatibilitySessionCoordinatorTests: XCTestCase {
    func testStandardSteamHandoffReconcilesOnlyAnOwnedActiveCompatibilitySession() {
        XCTAssertEqual(
            StandardSteamCompatibilitySessionHandoff.resolve(
                hasActiveCompatibilitySession: false,
                compatibilityTransitionInProgress: false,
                prefixLifecycleIsBusy: false
            ),
            .ready
        )
        XCTAssertEqual(
            StandardSteamCompatibilitySessionHandoff.resolve(
                hasActiveCompatibilitySession: true,
                compatibilityTransitionInProgress: false,
                prefixLifecycleIsBusy: true
            ),
            .reconcileActiveSession
        )
        XCTAssertEqual(
            StandardSteamCompatibilitySessionHandoff.resolve(
                hasActiveCompatibilitySession: true,
                compatibilityTransitionInProgress: true,
                prefixLifecycleIsBusy: true
            ),
            .blockedByCompatibilityTransition
        )
        XCTAssertEqual(
            StandardSteamCompatibilitySessionHandoff.resolve(
                hasActiveCompatibilitySession: false,
                compatibilityTransitionInProgress: false,
                prefixLifecycleIsBusy: true
            ),
            .blockedByAnotherPrefixOperation
        )
    }

    func testStandardSteamReservationBindsExactSessionAndBlocksCompatibilityMutation() throws {
        var gate = StandardSteamLaunchReservationGate()
        let originalIdentity = StandardSteamCompatibilitySessionIdentity(
            receiptID: "receipt-original",
            requestDigest: "request-original"
        )
        let reservation = try gate.reserve(
            hasActiveCompatibilitySession: true,
            activeCompatibilitySessionIdentity: originalIdentity,
            compatibilityTransitionInProgress: false,
            prefixLifecycleIsBusy: true
        )

        XCTAssertTrue(reservation.requiresCompatibilityReconciliation)
        XCTAssertTrue(gate.isReserved)
        XCTAssertThrowsError(try gate.requireCompatibilityMutationAllowed()) { error in
            XCTAssertEqual(
                error as? NavigationStableSessionOwnershipError,
                .standardSteamLaunchReserved
            )
        }
        XCTAssertNoThrow(
            try gate.validateExpectedCompatibilitySession(
                for: reservation,
                currentIdentity: originalIdentity
            )
        )

        let replacementIdentity = StandardSteamCompatibilitySessionIdentity(
            receiptID: "receipt-replacement",
            requestDigest: "request-replacement"
        )
        XCTAssertThrowsError(
            try gate.validateExpectedCompatibilitySession(
                for: reservation,
                currentIdentity: replacementIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? NavigationStableSessionOwnershipError,
                .standardSteamLaunchReservationMismatch
            )
        }
        XCTAssertThrowsError(
            try gate.validateReadyForStandardLaunch(
                reservation,
                hasActiveCompatibilitySession: false,
                compatibilityTransitionInProgress: false,
                prefixLifecycleIsBusy: true
            )
        ) { error in
            XCTAssertEqual(
                error as? NavigationStableSessionOwnershipError,
                .standardSteamLaunchNotReady
            )
        }
        XCTAssertNoThrow(
            try gate.validateReadyForStandardLaunch(
                reservation,
                hasActiveCompatibilitySession: false,
                compatibilityTransitionInProgress: false,
                prefixLifecycleIsBusy: false
            )
        )

        gate.release(
            StandardSteamLaunchReservation(
                id: UUID(),
                expectedCompatibilitySessionIdentity: originalIdentity
            )
        )
        XCTAssertTrue(gate.isReserved)
        gate.release(
            StandardSteamLaunchReservation(
                id: reservation.id,
                expectedCompatibilitySessionIdentity: replacementIdentity
            )
        )
        XCTAssertTrue(gate.isReserved)
        XCTAssertThrowsError(try gate.requireCompatibilityMutationAllowed()) { error in
            XCTAssertEqual(
                error as? NavigationStableSessionOwnershipError,
                .standardSteamLaunchReserved
            )
        }

        gate.release(reservation)
        XCTAssertFalse(gate.isReserved)
        XCTAssertNoThrow(try gate.requireCompatibilityMutationAllowed())
    }

    func testStandardSteamReservationRejectsTransitionAndUnownedBusyPrefix() {
        var transitionGate = StandardSteamLaunchReservationGate()
        XCTAssertThrowsError(
            try transitionGate.reserve(
                hasActiveCompatibilitySession: false,
                activeCompatibilitySessionIdentity: nil,
                compatibilityTransitionInProgress: true,
                prefixLifecycleIsBusy: true
            )
        ) { error in
            XCTAssertEqual(
                error as? NavigationStableSessionOwnershipError,
                .standardSteamLaunchReserved
            )
        }

        var busyGate = StandardSteamLaunchReservationGate()
        XCTAssertThrowsError(
            try busyGate.reserve(
                hasActiveCompatibilitySession: false,
                activeCompatibilitySessionIdentity: nil,
                compatibilityTransitionInProgress: false,
                prefixLifecycleIsBusy: true
            )
        ) { error in
            XCTAssertEqual(
                error as? NavigationStableSessionOwnershipError,
                .standardSteamLaunchNotReady
            )
        }
    }

    func testWindowsExecutableReservationTruthTableUsesExactConflictPrecedenceAndErrors()
        throws
    {
        let cases: [(
            active: Bool,
            transition: Bool,
            standard: Bool,
            busy: Bool,
            unreserved: WindowsExecutableLaunchReservationAvailability,
            reserved: WindowsExecutableLaunchReservationAvailability
        )] = [
            (false, false, false, false, .available, .blockedByWindowsExecutableLaunch),
            (false, false, false, true, .blockedByPrefixLifecycle, .blockedByWindowsExecutableLaunch),
            (false, false, true, false, .blockedByStandardSteamLaunch, .blockedByStandardSteamLaunch),
            (false, false, true, true, .blockedByStandardSteamLaunch, .blockedByStandardSteamLaunch),
            (false, true, false, false, .blockedByCompatibilityTransition, .blockedByCompatibilityTransition),
            (false, true, false, true, .blockedByCompatibilityTransition, .blockedByCompatibilityTransition),
            (false, true, true, false, .blockedByCompatibilityTransition, .blockedByCompatibilityTransition),
            (false, true, true, true, .blockedByCompatibilityTransition, .blockedByCompatibilityTransition),
            (true, false, false, false, .blockedByCompatibilitySession, .blockedByCompatibilitySession),
            (true, false, false, true, .blockedByCompatibilitySession, .blockedByCompatibilitySession),
            (true, false, true, false, .blockedByStandardSteamLaunch, .blockedByStandardSteamLaunch),
            (true, false, true, true, .blockedByStandardSteamLaunch, .blockedByStandardSteamLaunch),
            (true, true, false, false, .blockedByCompatibilityTransition, .blockedByCompatibilityTransition),
            (true, true, false, true, .blockedByCompatibilityTransition, .blockedByCompatibilityTransition),
            (true, true, true, false, .blockedByCompatibilityTransition, .blockedByCompatibilityTransition),
            (true, true, true, true, .blockedByCompatibilityTransition, .blockedByCompatibilityTransition)
        ]
        let coveredMasks = Set(cases.map { testCase in
            (testCase.active ? 8 : 0)
                | (testCase.transition ? 4 : 0)
                | (testCase.standard ? 2 : 0)
                | (testCase.busy ? 1 : 0)
        })
        XCTAssertEqual(coveredMasks, Set(0..<16))
        XCTAssertEqual(
            WindowsExecutableLaunchReservationAvailability
                .blockedByStandardSteamLaunch.error,
            .windowsExecutableLaunchNotReady
        )
        XCTAssertEqual(
            NavigationStableSessionOwnershipError
                .windowsExecutableLaunchNotReady.errorDescription,
            "Steam 실행 또는 다른 프리픽스 작업이 끝날 때까지 기다리세요."
        )

        for testCase in cases {
            var unreservedGate = WindowsExecutableLaunchReservationGate()
            XCTAssertEqual(
                unreservedGate.availability(
                    hasActiveCompatibilitySession: testCase.active,
                    compatibilityTransitionInProgress: testCase.transition,
                    standardSteamLaunchIsReserved: testCase.standard,
                    prefixLifecycleIsBusy: testCase.busy
                ),
                testCase.unreserved
            )

            if testCase.unreserved == .available {
                let reservation = try unreservedGate.reserve(
                    hasActiveCompatibilitySession: testCase.active,
                    compatibilityTransitionInProgress: testCase.transition,
                    standardSteamLaunchIsReserved: testCase.standard,
                    prefixLifecycleIsBusy: testCase.busy
                )
                XCTAssertTrue(unreservedGate.isReserved)
                unreservedGate.release(reservation)
                XCTAssertFalse(unreservedGate.isReserved)
            } else {
                XCTAssertThrowsError(
                    try unreservedGate.reserve(
                        hasActiveCompatibilitySession: testCase.active,
                        compatibilityTransitionInProgress: testCase.transition,
                        standardSteamLaunchIsReserved: testCase.standard,
                        prefixLifecycleIsBusy: testCase.busy
                    )
                ) { error in
                    XCTAssertEqual(
                        error as? NavigationStableSessionOwnershipError,
                        testCase.unreserved.error
                    )
                }
                XCTAssertFalse(unreservedGate.isReserved)
            }

            var reservedGate = WindowsExecutableLaunchReservationGate()
            let ownedReservation = try reservedGate.reserve(
                hasActiveCompatibilitySession: false,
                compatibilityTransitionInProgress: false,
                standardSteamLaunchIsReserved: false,
                prefixLifecycleIsBusy: false
            )
            XCTAssertEqual(
                reservedGate.availability(
                    hasActiveCompatibilitySession: testCase.active,
                    compatibilityTransitionInProgress: testCase.transition,
                    standardSteamLaunchIsReserved: testCase.standard,
                    prefixLifecycleIsBusy: testCase.busy
                ),
                testCase.reserved
            )
            XCTAssertThrowsError(
                try reservedGate.reserve(
                    hasActiveCompatibilitySession: testCase.active,
                    compatibilityTransitionInProgress: testCase.transition,
                    standardSteamLaunchIsReserved: testCase.standard,
                    prefixLifecycleIsBusy: testCase.busy
                )
            ) { error in
                XCTAssertEqual(
                    error as? NavigationStableSessionOwnershipError,
                    testCase.reserved.error
                )
            }
            reservedGate.release(ownedReservation)
            XCTAssertFalse(reservedGate.isReserved)
        }
    }

    func testWindowsExecutableReservationUsesExactTokenAndStaleReleaseCannotClearOwner()
        throws
    {
        var gate = WindowsExecutableLaunchReservationGate()
        let reservation = try gate.reserve(
            hasActiveCompatibilitySession: false,
            compatibilityTransitionInProgress: false,
            standardSteamLaunchIsReserved: false,
            prefixLifecycleIsBusy: false
        )
        XCTAssertEqual(
            gate.availability(
                hasActiveCompatibilitySession: false,
                compatibilityTransitionInProgress: false,
                standardSteamLaunchIsReserved: false,
                prefixLifecycleIsBusy: false
            ),
            .blockedByWindowsExecutableLaunch
        )
        XCTAssertThrowsError(
            try gate.requireCompatibilityOrStandardMutationAllowed()
        ) { error in
            XCTAssertEqual(
                error as? NavigationStableSessionOwnershipError,
                .windowsExecutableLaunchReserved
            )
        }

        gate.release(WindowsExecutableLaunchReservation(id: UUID()))
        XCTAssertTrue(gate.isReserved)
        gate.release(reservation)
        XCTAssertFalse(gate.isReserved)
    }

    @MainActor
    func testCoordinatorReservationBlocksStandardLaunchUntilExactRelease() throws {
        let coordinator = SteamCompatibilitySessionCoordinator()
        let reservation = try coordinator.reserveWindowsExecutableLaunch(
            prefixLifecycleIsBusy: false
        )

        XCTAssertTrue(coordinator.isWindowsExecutableLaunchReserved)
        XCTAssertThrowsError(
            try coordinator.reserveStandardSteamLaunch(
                prefixLifecycleIsBusy: false
            )
        ) { error in
            XCTAssertEqual(
                error as? NavigationStableSessionOwnershipError,
                .windowsExecutableLaunchReserved
            )
        }
        coordinator.releaseWindowsExecutableLaunchReservation(
            WindowsExecutableLaunchReservation(id: UUID())
        )
        XCTAssertTrue(coordinator.isWindowsExecutableLaunchReserved)
        coordinator.releaseWindowsExecutableLaunchReservation(reservation)
        XCTAssertFalse(coordinator.isWindowsExecutableLaunchReserved)
        XCTAssertNoThrow(
            try coordinator.reserveStandardSteamLaunch(
                prefixLifecycleIsBusy: false
            )
        )
    }

    func testStandardSteamReservationFailurePolicyMapsEveryOwnershipError() {
        let cases: [(
            error: NavigationStableSessionOwnershipError,
            expectedLocalizationKey: String
        )] = [
            (
                .transitionInProgress,
                "호환성 Steam 세션 작업이 이미 진행 중입니다."
            ),
            (
                .sessionAlreadyActive,
                "기존 호환성 Steam 세션을 먼저 종료하고 기준 상태 복원을 확인하세요."
            ),
            (
                .noActiveSession,
                "종료할 활성 호환성 Steam 세션이 없습니다."
            ),
            (
                .preparationNotInProgress,
                "호환성 Steam 세션 준비 상태가 올바르지 않습니다."
            ),
            (
                .standardSteamLaunchReserved,
                "일반 Steam 실행 전환이 진행 중입니다."
            ),
            (
                .standardSteamLaunchReservationMismatch,
                "일반 Steam 실행 전환 중 호환성 세션 상태가 변경되었습니다."
            ),
            (
                .standardSteamLaunchNotReady,
                "호환성 세션 복원 또는 다른 프리픽스 작업이 끝나지 않았습니다."
            ),
            (
                .windowsExecutableLaunchReserved,
                "다른 EXE 실행이 끝날 때까지 기다리세요."
            ),
            (
                .windowsExecutableLaunchBlockedByCompatibilitySession,
                "활성 호환성 Steam 세션을 먼저 종료하세요."
            ),
            (
                .windowsExecutableLaunchBlockedByCompatibilityTransition,
                "호환성 Steam 세션 전환이 끝날 때까지 기다리세요."
            ),
            (
                .windowsExecutableLaunchNotReady,
                "Steam 실행 또는 다른 프리픽스 작업이 끝날 때까지 기다리세요."
            )
        ]

        XCTAssertEqual(cases.count, 11)
        for testCase in cases {
            XCTAssertEqual(
                StandardSteamLaunchReservationFailurePolicy.localizationKey(
                    for: testCase.error
                ),
                testCase.expectedLocalizationKey
            )
        }
    }

    @MainActor
    func testStandardSteamAvailabilityAndAtomicReservationRaceReportEXEOwner()
        throws
    {
        let coordinator = SteamCompatibilitySessionCoordinator()
        XCTAssertNil(
            StandardSteamLaunchReservationFailurePolicy
                .preflightBlockerLocalizationKey(
                    isWindowsExecutableLaunchReserved:
                        coordinator.isWindowsExecutableLaunchReserved
                )
        )

        // Simulates an EXE reservation acquired after the view's availability
        // read but before the standard launch's atomic reservation attempt.
        let exeReservation = try coordinator.reserveWindowsExecutableLaunch(
            prefixLifecycleIsBusy: false
        )
        defer {
            coordinator.releaseWindowsExecutableLaunchReservation(exeReservation)
        }

        XCTAssertEqual(
            StandardSteamLaunchReservationFailurePolicy
                .preflightBlockerLocalizationKey(
                    isWindowsExecutableLaunchReserved:
                        coordinator.isWindowsExecutableLaunchReserved
                ),
            "다른 EXE 실행이 끝날 때까지 기다리세요."
        )
        XCTAssertThrowsError(
            try coordinator.reserveStandardSteamLaunch(
                prefixLifecycleIsBusy: false
            )
        ) { error in
            let ownershipError = error as? NavigationStableSessionOwnershipError
            XCTAssertEqual(ownershipError, .windowsExecutableLaunchReserved)
            XCTAssertEqual(
                ownershipError.map {
                    StandardSteamLaunchReservationFailurePolicy.localizationKey(
                        for: $0
                    )
                },
                "다른 EXE 실행이 끝날 때까지 기다리세요."
            )
            XCTAssertNotEqual(
                ownershipError.map {
                    StandardSteamLaunchReservationFailurePolicy.localizationKey(
                        for: $0
                    )
                },
                "호환성 Steam 세션 작업이 이미 진행 중입니다."
            )
        }
    }

    @MainActor
    func testEXEReservationBlocksEveryCompatibilityAndStandardMutationBeforeDownstreamWork()
        async throws
    {
        let coordinator = SteamCompatibilitySessionCoordinator()
        let reservation = try coordinator.reserveWindowsExecutableLaunch(
            prefixLifecycleIsBusy: false
        )
        defer {
            coordinator.releaseWindowsExecutableLaunchReservation(reservation)
        }

        let recipe = SteamCompatibilityLaunchProfileCatalogV1.helldivers2
        let unresolvedBookmark = try CompatibilityUnresolvedManifestRootBookmarkV1(
            securityScopedBookmark: Data([1])
        )
        let runtimeContext = try SteamManagerCompatibilityLaunchContextV1(
            runtimeExecutableBookmark: Data([2]),
            steamClientLanguage: .english
        )

        do {
            _ = try await coordinator.prepareSteamSession(
                recipe: recipe,
                unresolvedManifestRootBookmark: unresolvedBookmark,
                savedPreference: nil,
                oneLaunchOverride: CompatibilitySteamLaunchOneLaunchOverrideV1(
                    identity: recipe.identity
                ),
                displaySelections: recipe.initialSelections,
                displayFieldProvenance: [:],
                runtimeContext: runtimeContext,
                manifestRootAuthorizationProvider:
                    UnavailableCompatibilityManifestRootAuthorizationProviderV1(),
                runtimeProviderFactory: { _ in
                    UnavailableCompatibilityLaunchRuntimeProviderV1()
                }
            )
            XCTFail("Compatibility preparation bypassed the EXE reservation")
        } catch {
            XCTAssertEqual(
                error as? NavigationStableSessionOwnershipError,
                .windowsExecutableLaunchReserved
            )
        }

        do {
            _ = try await coordinator.completeSteamSession()
            XCTFail("Compatibility completion bypassed the EXE reservation")
        } catch {
            XCTAssertEqual(
                error as? NavigationStableSessionOwnershipError,
                .windowsExecutableLaunchReserved
            )
        }

        XCTAssertThrowsError(
            try coordinator.reserveStandardSteamLaunch(
                prefixLifecycleIsBusy: false
            )
        ) { error in
            XCTAssertEqual(
                error as? NavigationStableSessionOwnershipError,
                .windowsExecutableLaunchReserved
            )
        }
    }

    @MainActor
    func testOwnerRetainsProviderAfterViewClientIsReleasedAndDropsItAfterCompletion()
        async throws
    {
        let owner = NavigationStableSessionOwner<Int, LeaseProbe, String>()
        weak var retainedProvider: LeaseProbe?

        do {
            let provider = LeaseProbe()
            retainedProvider = provider
            var viewClient: SessionViewClient? = SessionViewClient(owner: owner)
            try viewClient?.activate(
                session: 41,
                provider: provider,
                presentation: "recipe-41"
            )

            // Simulates navigating away and releasing the SwiftUI view/client.
            viewClient = nil
        }

        XCTAssertTrue(owner.hasActiveSession)
        XCTAssertEqual(owner.lastSession, 41)
        XCTAssertEqual(owner.activePresentation, "recipe-41")
        XCTAssertNotNil(retainedProvider)

        let completed = try await owner.completeActiveSession { provider, session in
            provider.completionAttempts += 1
            return session + 1
        }

        XCTAssertEqual(completed, 42)
        XCTAssertEqual(owner.lastSession, 42)
        XCTAssertFalse(owner.hasActiveSession)
        XCTAssertNil(owner.activePresentation)
        XCTAssertFalse(owner.isTransitionInProgress)
        XCTAssertNil(retainedProvider)
    }

    @MainActor
    func testCompletionFailureRetainsExactSessionAndProviderForSuccessfulRetry()
        async throws
    {
        let owner = NavigationStableSessionOwner<Int, LeaseProbe, String>()
        let provider = LeaseProbe()
        try owner.beginPreparation()
        try owner.commitPreparedSession(
            7,
            provider: provider,
            presentation: "recipe-7"
        )

        do {
            _ = try await owner.completeActiveSession { provider, _ in
                provider.completionAttempts += 1
                throw ProbeFailure.expected
            }
            XCTFail("Completion failure unexpectedly cleared the active session")
        } catch {
            XCTAssertEqual(error as? ProbeFailure, .expected)
        }

        XCTAssertTrue(owner.hasActiveSession)
        XCTAssertEqual(owner.lastSession, 7)
        XCTAssertEqual(owner.activePresentation, "recipe-7")
        XCTAssertFalse(owner.isTransitionInProgress)
        XCTAssertEqual(provider.completionAttempts, 1)

        let completed = try await owner.completeActiveSession { provider, session in
            provider.completionAttempts += 1
            return session + 10
        }

        XCTAssertEqual(completed, 17)
        XCTAssertEqual(owner.lastSession, 17)
        XCTAssertFalse(owner.hasActiveSession)
        XCTAssertNil(owner.activePresentation)
        XCTAssertEqual(provider.completionAttempts, 2)
    }

    @MainActor
    func testNonthrowingIncompleteCompletionRetainsProviderReceiptAndPresentation()
        async throws
    {
        let owner = NavigationStableSessionOwner<Int, LeaseProbe, String>()
        let provider = LeaseProbe()
        try owner.beginPreparation()
        try owner.commitPreparedSession(
            9,
            provider: provider,
            presentation: "recipe-9"
        )

        do {
            _ = try await owner.completeActiveSession(
                validating: { original, completed in
                    guard completed != original else {
                        throw ProbeFailure.incompleteCompletion
                    }
                }
            ) { provider, session in
                provider.completionAttempts += 1
                return session
            }
            XCTFail("An incomplete nonthrowing completion released the provider")
        } catch {
            XCTAssertEqual(error as? ProbeFailure, .incompleteCompletion)
        }

        XCTAssertTrue(owner.hasActiveSession)
        XCTAssertEqual(owner.lastSession, 9)
        XCTAssertEqual(owner.activePresentation, "recipe-9")
        XCTAssertFalse(owner.isTransitionInProgress)
        XCTAssertEqual(provider.completionAttempts, 1)
    }

    @MainActor
    func testPreparationFailureAndSecondSessionGateLeaveDeterministicOwnershipState()
        throws
    {
        let owner = NavigationStableSessionOwner<Int, LeaseProbe, String>()

        try owner.beginPreparation()
        owner.failPreparation()
        XCTAssertFalse(owner.isTransitionInProgress)
        XCTAssertFalse(owner.hasActiveSession)
        XCTAssertNil(owner.lastSession)

        try owner.beginPreparation()
        try owner.commitPreparedSession(
            3,
            provider: LeaseProbe(),
            presentation: "recipe-3"
        )
        XCTAssertThrowsError(try owner.beginPreparation()) { error in
            XCTAssertEqual(
                error as? NavigationStableSessionOwnershipError,
                .sessionAlreadyActive
            )
        }
        XCTAssertTrue(owner.hasActiveSession)
        XCTAssertEqual(owner.lastSession, 3)
        XCTAssertEqual(owner.activePresentation, "recipe-3")

        owner.clearCompletedSession()
        XCTAssertTrue(owner.hasActiveSession)
        XCTAssertEqual(owner.lastSession, 3)
        XCTAssertEqual(owner.activePresentation, "recipe-3")
    }

    @MainActor
    func testApplicationTerminationCompletesCompatibilityOwnershipBeforeLifecycleAdmissionExactlyOnce()
        async throws
    {
        let services = AppServices(appSessionID: "termination-success")
        let coordinator = services.steamCompatibilitySessionCoordinator
        let provider = AppTerminationRuntimeProviderProbe()
        let original = try await prepareActiveCompatibilitySession(
            coordinator: coordinator,
            provider: provider
        )
        provider.lifecycleTerminationState = {
            services.steamPrefixLifecycleCoordinator.isTerminating
        }

        let summary = await services.shutdownSteamProcessesForAppTermination(
            runtimeExecutable: nil
        )

        XCTAssertTrue(summary.succeeded, summary.diagnosticDescription)
        XCTAssertEqual(provider.terminationCompletionCalls, 1)
        XCTAssertEqual(provider.normalCompletionCalls, 0)
        XCTAssertEqual(provider.observedLifecycleTerminationStates, [true])
        XCTAssertEqual(provider.ownershipReleaseCount, 1)
        XCTAssertFalse(provider.hasPersistentLeaseAndScopes)
        XCTAssertTrue(services.steamPrefixLifecycleCoordinator.isTerminating)
        XCTAssertFalse(coordinator.hasActiveSession)
        XCTAssertEqual(
            coordinator.lastPreparation?.receipt.evidence.restoredBaselineDigest,
            original.receipt.evidence.capturedBaselineDigest
        )

        let duplicate = try await coordinator
            .completeActiveSessionForApplicationTerminationIfNeeded()
        XCTAssertNil(duplicate)
        XCTAssertEqual(provider.terminationCompletionCalls, 1)
        XCTAssertEqual(provider.ownershipReleaseCount, 1)
    }

    @MainActor
    func testForceStopThenImmediateTerminationDoesNotCompleteActiveProviderThroughWine()
        async throws
    {
        let services = AppServices(appSessionID: "force-stop-active-provider")
        let coordinator = services.steamCompatibilitySessionCoordinator
        let provider = AppTerminationRuntimeProviderProbe()
        _ = try await prepareActiveCompatibilitySession(
            coordinator: coordinator,
            provider: provider
        )
        XCTAssertTrue(coordinator.hasActiveSession)
        XCTAssertTrue(provider.hasPersistentLeaseAndScopes)

        let forceResult = await services
            .forceTerminateAllForgePlayWineProcesses(forceTerminator: {
                StartupWineProcessCleanupResult(
                    initiallyTargetedProcessIDs: [88],
                    remainingProcessIDs: [],
                    inspectionFailures: [],
                    signalFailures: []
                )
            })
        XCTAssertTrue(forceResult.succeeded)
        XCTAssertTrue(coordinator.hasActiveSession)
        XCTAssertEqual(provider.terminationCompletionCalls, 0)

        let summary = await services.shutdownSteamProcessesForAppTermination(
            runtimeExecutable: nil,
            wineProcessInspector: {
                StartupWineProcessCleanupPlan(
                    targets: [],
                    inspectionFailures: []
                )
            }
        )

        XCTAssertTrue(summary.succeeded, summary.diagnosticDescription)
        XCTAssertTrue(summary.results.isEmpty, summary.diagnosticDescription)
        XCTAssertEqual(provider.terminationCompletionCalls, 0)
        XCTAssertEqual(provider.normalCompletionCalls, 0)
        XCTAssertTrue(
            provider.hasPersistentLeaseAndScopes,
            "Force stop must preserve the truthful incomplete receipt until app teardown or an explicit next-launch reconciliation"
        )
        XCTAssertTrue(coordinator.hasActiveSession)
    }

    @MainActor
    func testNewLifecycleOperationInvalidatesEarlierForceStopProof()
        async throws
    {
        let services = AppServices(appSessionID: "force-stop-proof-generation")
        let coordinator = services.steamCompatibilitySessionCoordinator
        let provider = AppTerminationRuntimeProviderProbe()
        _ = try await prepareActiveCompatibilitySession(
            coordinator: coordinator,
            provider: provider
        )
        let forceResult = await services
            .forceTerminateAllForgePlayWineProcesses(forceTerminator: {
                StartupWineProcessCleanupResult(
                    initiallyTargetedProcessIDs: [99],
                    remainingProcessIDs: [],
                    inspectionFailures: [],
                    signalFailures: []
                )
            })
        XCTAssertTrue(forceResult.succeeded)

        let token = try services.steamPrefixLifecycleCoordinator
            .begin(.maintenance)
        services.steamPrefixLifecycleCoordinator.end(token)

        let summary = await services.shutdownSteamProcessesForAppTermination(
            runtimeExecutable: nil,
            wineProcessInspector: {
                StartupWineProcessCleanupPlan(
                    targets: [],
                    inspectionFailures: []
                )
            }
        )

        XCTAssertTrue(summary.succeeded, summary.diagnosticDescription)
        XCTAssertEqual(provider.terminationCompletionCalls, 1)
        XCTAssertFalse(coordinator.hasActiveSession)
        XCTAssertFalse(provider.hasPersistentLeaseAndScopes)
    }

    @MainActor
    func testApplicationTerminationRestorationFailureDeniesAdmissionAndRetainsOwnerForRetry()
        async throws
    {
        let services = AppServices(
            appSessionID: "termination-restoration-retry"
        )
        let coordinator = services.steamCompatibilitySessionCoordinator
        let provider = AppTerminationRuntimeProviderProbe()
        provider.shouldFailRestoration = true
        let original = try await prepareActiveCompatibilitySession(
            coordinator: coordinator,
            provider: provider
        )
        provider.lifecycleTerminationState = {
            services.steamPrefixLifecycleCoordinator.isTerminating
        }

        let failedSummary = await services.shutdownSteamProcessesForAppTermination(
            runtimeExecutable: nil
        )

        XCTAssertFalse(failedSummary.succeeded)
        XCTAssertTrue(
            failedSummary.errors.joined(separator: " ").contains(
                "could not safely complete the active compatibility Steam session"
            ),
            failedSummary.diagnosticDescription
        )
        XCTAssertTrue(services.steamPrefixLifecycleCoordinator.isTerminating)
        XCTAssertTrue(coordinator.hasActiveSession)
        XCTAssertFalse(coordinator.isTransitionInProgress)
        XCTAssertEqual(coordinator.lastPreparation, original)
        XCTAssertNil(
            coordinator.lastPreparation?.receipt.evidence.restoredBaselineDigest
        )
        XCTAssertTrue(provider.hasPersistentLeaseAndScopes)
        XCTAssertEqual(provider.ownershipReleaseCount, 0)
        XCTAssertEqual(provider.terminationCompletionCalls, 1)
        XCTAssertEqual(provider.observedLifecycleTerminationStates, [true])

        provider.shouldFailRestoration = false
        let retrySummary = await services.shutdownSteamProcessesForAppTermination(
            runtimeExecutable: nil
        )

        XCTAssertTrue(retrySummary.succeeded, retrySummary.diagnosticDescription)
        XCTAssertTrue(services.steamPrefixLifecycleCoordinator.isTerminating)
        XCTAssertFalse(coordinator.hasActiveSession)
        XCTAssertEqual(provider.terminationCompletionCalls, 2)
        XCTAssertEqual(provider.observedLifecycleTerminationStates, [true, true])
        XCTAssertEqual(provider.ownershipReleaseCount, 1)
        XCTAssertFalse(provider.hasPersistentLeaseAndScopes)
        XCTAssertEqual(
            coordinator.lastPreparation?.receipt.evidence.restoredBaselineDigest,
            original.receipt.evidence.capturedBaselineDigest
        )
    }

    @MainActor
    func testApplicationTerminationDrainsFailedPostLaunchCleanupBeforeLifecycleAdmissionAndRetainsItOnFailure()
        async throws
    {
        let services = AppServices(
            appSessionID: "termination-failed-cleanup-drain"
        )
        let owner = FailedCleanupOwnerProbe()
        owner.lifecycleTerminationState = {
            services.steamPrefixLifecycleCoordinator.isTerminating
        }
        try services.steamPrefixService
            .retainFailedCompatibilityCleanupOwner(owner)

        let failedSummary = await services.shutdownSteamProcessesForAppTermination(
            runtimeExecutable: nil
        )

        XCTAssertFalse(failedSummary.succeeded)
        XCTAssertTrue(services.steamPrefixLifecycleCoordinator.isTerminating)
        XCTAssertEqual(
            services.steamPrefixService
                .failedCompatibilityCleanupOwnerCountForTesting,
            1
        )
        XCTAssertEqual(owner.completionReasons, [.applicationTermination])
        XCTAssertEqual(owner.observedLifecycleTerminationStates, [true])
        XCTAssertEqual(owner.ownershipReleaseCount, 0)

        owner.shouldFailRestoration = false
        let retrySummary = await services.shutdownSteamProcessesForAppTermination(
            runtimeExecutable: nil
        )

        XCTAssertTrue(retrySummary.succeeded, retrySummary.diagnosticDescription)
        XCTAssertTrue(services.steamPrefixLifecycleCoordinator.isTerminating)
        XCTAssertEqual(
            services.steamPrefixService
                .failedCompatibilityCleanupOwnerCountForTesting,
            0
        )
        XCTAssertEqual(
            owner.completionReasons,
            [.applicationTermination, .applicationTermination]
        )
        XCTAssertEqual(owner.observedLifecycleTerminationStates, [true, true])
        XCTAssertEqual(owner.ownershipReleaseCount, 1)
    }

    @MainActor
    func testManagedRootChangeIsBlockedWhileFailedCompatibilityCleanupOwnsPrefix()
        async throws
    {
        let services = AppServices(
            appSessionID: "root-change-failed-cleanup-owner"
        )
        let owner = FailedCleanupOwnerProbe()
        try services.steamPrefixService
            .retainFailedCompatibilityCleanupOwner(owner)

        do {
            _ = try await services.shutdownSteamProcessesBeforeRootChange(
                from: URL(
                    fileURLWithPath: "/tmp/forgeplay-root-change-blocked",
                    isDirectory: true
                ),
                runtimeExecutable: nil
            )
            XCTFail("Root change unexpectedly crossed retained cleanup ownership")
        } catch {
            XCTAssertEqual(
                error as? SteamPrefixLifecycleError,
                .operationInProgress
            )
        }
        XCTAssertEqual(
            services.steamPrefixService
                .failedCompatibilityCleanupOwnerCountForTesting,
            1
        )
        XCTAssertTrue(owner.completionReasons.isEmpty)
        XCTAssertEqual(owner.ownershipReleaseCount, 0)
    }

    @MainActor
    private func prepareActiveCompatibilitySession(
        coordinator: SteamCompatibilitySessionCoordinator,
        provider: AppTerminationRuntimeProviderProbe
    ) async throws -> CompatibilitySteamLaunchPreparationV1 {
        let recipe = SteamCompatibilityLaunchProfileCatalogV1.helldivers2
        return try await coordinator.prepareSteamSession(
            recipe: recipe,
            unresolvedManifestRootBookmark:
                CompatibilityUnresolvedManifestRootBookmarkV1(
                    securityScopedBookmark: Data("termination-manifest".utf8)
                ),
            savedPreference: nil,
            oneLaunchOverride: CompatibilitySteamLaunchOneLaunchOverrideV1(
                identity: recipe.identity
            ),
            displaySelections: recipe.initialSelections,
            displayFieldProvenance: [:],
            runtimeContext: SteamManagerCompatibilityLaunchContextV1(
                runtimeExecutableBookmark: Data("termination-runtime".utf8),
                steamClientLanguage: .english
            ),
            manifestRootAuthorizationProvider:
                AppTerminationManifestAuthorizationProvider(),
            runtimeProviderFactory: { _ in provider }
        )
    }

    @MainActor
    private final class SessionViewClient {
        private let owner: NavigationStableSessionOwner<Int, LeaseProbe, String>

        init(owner: NavigationStableSessionOwner<Int, LeaseProbe, String>) {
            self.owner = owner
        }

        func activate(
            session: Int,
            provider: LeaseProbe,
            presentation: String
        ) throws {
            try owner.beginPreparation()
            try owner.commitPreparedSession(
                session,
                provider: provider,
                presentation: presentation
            )
        }
    }

    private final class LeaseProbe {
        var completionAttempts = 0
    }

    private struct AppTerminationManifestAuthorizationProvider:
        CompatibilityManifestRootAuthorizationProviderV1
    {
        func resolveAndPinManifestRoot(
            bookmark: CompatibilityUnresolvedManifestRootBookmarkV1
        ) async throws -> CompatibilityManifestRootAuthorizationTokenV1 {
            try CompatibilityManifestRootAuthorizationTokenV1(
                providerID: "forgeplay.test-termination-manifest-v1",
                sourceBookmark: bookmark,
                pinnedVolumeIdentifier: Data("termination-volume".utf8),
                pinnedFileIdentifier: Data("termination-file".utf8)
            )
        }
    }

    @MainActor
    private final class AppTerminationRuntimeProviderProbe:
        CompatibilityLaunchRuntimeProviderV1
    {
        private static let providerID =
            "forgeplay.test-termination-runtime-v1"

        var shouldFailRestoration = false
        var lifecycleTerminationState: @MainActor () -> Bool = { false }
        private(set) var terminationCompletionCalls = 0
        private(set) var normalCompletionCalls = 0
        private(set) var observedLifecycleTerminationStates: [Bool] = []
        private(set) var ownershipReleaseCount = 0
        private(set) var hasPersistentLeaseAndScopes = false

        func capabilities() async throws
            -> CompatibilitySteamLaunchRuntimeCapabilitiesV1
        {
            .supporting(
                recipe: SteamCompatibilityLaunchProfileCatalogV1.helldivers2
            )
        }

        func prepareSteamSession(
            request: ResolvedCompatibilityLaunchRequestV1
        ) async throws -> CompatibilityLaunchApplicationReceiptV1 {
            hasPersistentLeaseAndScopes = true
            return try Self.makeReceipt(for: request)
        }

        func completeSteamSession(
            receipt: CompatibilityLaunchApplicationReceiptV1
        ) async throws -> CompatibilityLaunchApplicationReceiptV1 {
            normalCompletionCalls += 1
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "unexpected-normal-completion"
            )
        }

        func completeSteamSessionForApplicationTermination(
            receipt: CompatibilityLaunchApplicationReceiptV1
        ) async throws -> CompatibilityLaunchApplicationReceiptV1 {
            terminationCompletionCalls += 1
            observedLifecycleTerminationStates.append(
                lifecycleTerminationState()
            )
            if shouldFailRestoration {
                throw ProbeFailure.expected
            }
            guard hasPersistentLeaseAndScopes else {
                throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                    "termination-ownership-already-released"
                )
            }
            let completed = try Self.makeCompletedReceipt(from: receipt)
            hasPersistentLeaseAndScopes = false
            ownershipReleaseCount += 1
            return completed
        }

        private static func makeReceipt(
            for request: ResolvedCompatibilityLaunchRequestV1
        ) throws -> CompatibilityLaunchApplicationReceiptV1 {
            let beforeDigest = String(repeating: "a", count: 64)
            let afterDigest = String(repeating: "b", count: 64)
            let componentEvidence =
                CompatibilityRuntimeApplicationEvidenceV1
                    .expectedMutationComponentIDs.sorted().map { componentID in
                        CompatibilityRuntimeComponentMutationEvidenceV1(
                            componentID: componentID,
                            beforeDigest: beforeDigest,
                            afterDigest: afterDigest,
                            readbackDigest: afterDigest
                        )
                    }
            return try CompatibilityLaunchApplicationReceiptV1(
                providerID: providerID,
                receiptID:
                    "termination-" +
                    request.transactionID.uuidString.lowercased(),
                requestDigest: request.canonicalDigest,
                transactionID: request.transactionID,
                evidence: CompatibilityRuntimeApplicationEvidenceV1(
                    appliedRequestDigest: request.canonicalDigest,
                    capturedBaselineDigest: String(repeating: "c", count: 64),
                    appliedStateDigest: String(repeating: "d", count: 64),
                    providerReadbackDigest: String(repeating: "e", count: 64),
                    componentMutationEvidence: componentEvidence
                )
            )
        }

        private static func makeCompletedReceipt(
            from receipt: CompatibilityLaunchApplicationReceiptV1
        ) throws -> CompatibilityLaunchApplicationReceiptV1 {
            try CompatibilityLaunchApplicationReceiptV1(
                providerID: receipt.providerID,
                receiptID: receipt.receiptID,
                requestDigest: receipt.requestDigest,
                transactionID: receipt.transactionID,
                evidence: CompatibilityRuntimeApplicationEvidenceV1(
                    appliedRequestDigest: receipt.evidence.appliedRequestDigest,
                    capturedBaselineDigest:
                        receipt.evidence.capturedBaselineDigest,
                    appliedStateDigest: receipt.evidence.appliedStateDigest,
                    providerReadbackDigest:
                        receipt.evidence.providerReadbackDigest,
                    componentMutationEvidence:
                        receipt.evidence.componentMutationEvidence,
                    restoredBaselineDigest:
                        receipt.evidence.capturedBaselineDigest
                )
            )
        }
    }

    @MainActor
    private final class FailedCleanupOwnerProbe:
        SteamCompatibilityFailedCleanupOwner
    {
        let cleanupReceiptID = "failed-cleanup-termination-probe"
        let prefixBinding = SteamCompatibilityPrefixBinding(
            canonicalPrefixURL: URL(fileURLWithPath: "/tmp/forgeplay-test-prefix"),
            device: 10,
            inode: 20
        )
        let capturedBaselineDigest = String(repeating: "a", count: 64)

        var shouldFailRestoration = true
        var lifecycleTerminationState: @MainActor () -> Bool = { false }
        private(set) var completionReasons:
            [SteamCompatibilityFailedCleanupCompletionReason] = []
        private(set) var observedLifecycleTerminationStates: [Bool] = []
        private(set) var ownershipReleaseCount = 0

        func cancelCompatibilityBackgroundWork()
            -> [SteamCompatibilityBackgroundWorkCompletionState]
        {
            []
        }

        func completeFailedPostLaunchCleanup(
            using service: SteamPrefixService,
            reason: SteamCompatibilityFailedCleanupCompletionReason
        ) async throws -> SteamCompatibilityFailedCleanupCompletionProof {
            _ = service
            completionReasons.append(reason)
            observedLifecycleTerminationStates.append(
                lifecycleTerminationState()
            )
            if shouldFailRestoration {
                throw ProbeFailure.expected
            }
            ownershipReleaseCount += 1
            return SteamCompatibilityFailedCleanupCompletionProof(
                cleanupReceiptID: cleanupReceiptID,
                prefixBinding: prefixBinding,
                capturedBaselineDigest: capturedBaselineDigest,
                restoredBaselineDigest: capturedBaselineDigest
            )
        }
    }

    private enum ProbeFailure: Error, Equatable {
        case expected
        case incompleteCompletion
    }

}
