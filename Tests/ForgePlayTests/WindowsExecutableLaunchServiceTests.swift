import Foundation
import XCTest
@testable import ForgePlay

@MainActor
final class WindowsExecutableLaunchServiceTests: XCTestCase {
    private actor PrefixInactivityProbe {
        enum Outcome: Sendable {
            case active
            case inactive
            case failed
        }

        private var continuations: [CheckedContinuation<Bool, Error>] = []
        private(set) var callCount = 0

        func wait() async throws -> Bool {
            callCount += 1
            return try await withCheckedThrowingContinuation {
                continuations.append($0)
            }
        }

        func resumeNext(_ outcome: Outcome) {
            guard !continuations.isEmpty else { return }
            let continuation = continuations.removeFirst()
            switch outcome {
            case .active:
                continuation.resume(returning: false)
            case .inactive:
                continuation.resume(returning: true)
            case .failed:
                continuation.resume(throwing: ProbeError.readbackUnavailable)
            }
        }

        private enum ProbeError: Error {
            case readbackUnavailable
        }
    }

    private final class Lease: WindowsExecutableLaunchLease {
        private let onTransition: () -> Void
        private let onRelease: () -> Void

        init(
            onTransition: @escaping () -> Void,
            onRelease: @escaping () -> Void
        ) {
            self.onTransition = onTransition
            self.onRelease = onRelease
        }

        func transitionToSharedExecution() throws {
            onTransition()
        }

        func release() {
            onRelease()
        }
    }

    private final class ManagedRootLease: WindowsExecutableManagedRootLease {
        private let onRelease: () -> Void

        init(onRelease: @escaping () -> Void) {
            self.onRelease = onRelease
        }

        func release() {
            onRelease()
        }
    }

    private final class AccessLifetimeProbe {}

    private final class InspectionConcurrencyProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var activeCount = 0
        private var maximumActiveCountStorage = 0

        var maximumActiveCount: Int {
            lock.withLock { maximumActiveCountStorage }
        }

        func inspect(_ key: WindowsExecutableRendererCapabilityKey) -> Bool {
            lock.withLock {
                activeCount += 1
                maximumActiveCountStorage = max(
                    maximumActiveCountStorage,
                    activeCount
                )
            }
            Thread.sleep(forTimeInterval: 0.01)
            lock.withLock {
                activeCount -= 1
            }
            return key.backend.rendererPolicy != nil
        }
    }

    func testLaunchUsesSharedPrefixLifecycleAndCarriesRenderer() async throws {
        let prefix = URL(fileURLWithPath: "/tmp/ForgePlay/SteamShared")
        let runtime = URL(fileURLWithPath: "/tmp/ForgePlay/wine")
        let executable = URL(fileURLWithPath: "/tmp/ForgePlay/Tool.exe")
        let externalRoot = URL(
            fileURLWithPath: "/tmp/ForgePlay/External",
            isDirectory: true
        )
        let log = URL(fileURLWithPath: "/tmp/ForgePlay/launch.log")
        var events: [String] = []
        let reservation = WindowsExecutableLaunchReservation(id: UUID())
        let runtimeCapability = WindowsRuntimeCapability(
            executableURL: runtime,
            graphicsBackend: .moltenVKOrVulkan,
            evidence: ["test-capability"],
            limitations: []
        )

        let service = WindowsExecutableLaunchService(
            reservationProvider: {
                events.append("reservation")
                return reservation
            },
            reservationReleaser: { receivedReservation in
                XCTAssertEqual(receivedReservation, reservation)
                events.append("reservation-release")
            },
            prefixURLProvider: {
                events.append("prefix")
                return prefix
            },
            runtimeCompatibilityValidator: { receivedRuntime in
                XCTAssertEqual(receivedRuntime, runtime)
                events.append("runtime")
            },
            registerLifecycle: { receivedPrefix in
                XCTAssertEqual(receivedPrefix, prefix)
                events.append("lifecycle-begin")
            },
            lifecycleCheckpoint: {
                events.append("checkpoint")
            },
            unregisterLifecycle: { receivedPrefix in
                XCTAssertEqual(receivedPrefix, prefix)
                events.append("lifecycle-end")
            },
            managedRootLeaseProvider: {
                events.append("root-lease")
                return [
                    ManagedRootLease {
                        events.append("root-release")
                    }
                ]
            },
            leaseProvider: { receivedPrefix in
                XCTAssertEqual(receivedPrefix, prefix)
                events.append("lease")
                return Lease(
                    onTransition: { events.append("shared") },
                    onRelease: { events.append("release") }
                )
            },
            usablePrefixValidator: { receivedPrefix in
                XCTAssertEqual(receivedPrefix, prefix)
                events.append("usable")
            },
            rendererCapabilityValidator: {
                receivedRuntime,
                receivedPrefix,
                renderer in
                XCTAssertEqual(receivedRuntime, runtime)
                XCTAssertEqual(receivedPrefix, prefix)
                XCTAssertEqual(renderer, .d9vk)
                events.append("renderer")
                return runtimeCapability
            },
            launcher: {
                receivedRuntime,
                receivedPrefix,
                receivedExecutable,
                arguments,
                renderer,
                receivedRuntimeCapability,
                roots in
                XCTAssertEqual(receivedRuntime, runtime)
                XCTAssertEqual(receivedPrefix, prefix)
                XCTAssertEqual(receivedExecutable, executable)
                XCTAssertEqual(arguments, ["--repair"])
                XCTAssertEqual(renderer, .d9vk)
                XCTAssertEqual(
                    receivedRuntimeCapability,
                    runtimeCapability
                )
                XCTAssertEqual(roots, [externalRoot])
                events.append("launch")
                return ProcessRunResult(
                    actionName: "launchWindowsUtility",
                    executable: runtime,
                    arguments: [],
                    startedAt: Date(),
                    endedAt: Date(),
                    exitCode: 0,
                    stdoutLog: log,
                    stderrLog: log,
                    didTimeOut: false
                )
            }
        )

        _ = try await service.launch(
            runtimeExecutable: runtime,
            executable: executable,
            arguments: ["--repair"],
            rendererPolicy: .d9vk,
            externalStorageRoots: [externalRoot]
        )

        XCTAssertEqual(
            events,
            [
                "reservation",
                "root-lease",
                "prefix",
                "lifecycle-begin",
                "lease",
                "checkpoint",
                "usable",
                "runtime",
                "checkpoint",
                "shared",
                "checkpoint",
                "renderer",
                "checkpoint",
                "launch",
                "release",
                "lifecycle-end",
                "root-release",
                "reservation-release"
            ]
        )
    }

    func testDetachedUtilityRetainsSharedPrefixLeaseUntilExactInactivityReadback()
        async throws
    {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "forgeplay-windows-utility-lease-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let prefix = fixtureRoot.appending(
            path: "SteamShared",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let runtime = fixtureRoot.appending(path: "wine")
        let executable = fixtureRoot.appending(path: "Tool.exe")
        let log = fixtureRoot.appending(path: "launch.log")
        let reservation = WindowsExecutableLaunchReservation(id: UUID())
        let probe = PrefixInactivityProbe()
        let owner = WindowsExecutablePrefixExecutionLifetimeOwner(
            retryDelay: { _ in await Task.yield() }
        )
        var events: [String] = []
        let service = WindowsExecutableLaunchService(
            reservationProvider: {
                events.append("reservation")
                return reservation
            },
            reservationReleaser: { _ in
                events.append("reservation-release")
            },
            prefixURLProvider: { prefix },
            runtimeCompatibilityValidator: { _ in },
            registerLifecycle: { _ in events.append("lifecycle-begin") },
            lifecycleCheckpoint: {},
            unregisterLifecycle: { _ in events.append("lifecycle-end") },
            managedRootLeaseProvider: {
                [ManagedRootLease { events.append("root-release") }]
            },
            leaseProvider: { _ in
                Lease(
                    onTransition: { events.append("shared") },
                    onRelease: { events.append("lease-release") }
                )
            },
            usablePrefixValidator: { _ in },
            rendererCapabilityValidator: { _, _, _ in nil },
            launcher: { _, _, _, _, _, _, _ in
                ProcessRunResult(
                    actionName: "launchWindowsUtility",
                    executable: runtime,
                    arguments: [],
                    startedAt: Date(),
                    endedAt: Date(),
                    exitCode: 0,
                    hasProcessExitCode: false,
                    stdoutLog: log,
                    stderrLog: log,
                    didTimeOut: false,
                    waitedForExit: false,
                    outcome: .runningDetached,
                    processIdentifier: 4242
                )
            },
            prefixExecutionLifetimeOwner: owner,
            prefixInactivityWaiter: { _, _, _ in
                try await probe.wait()
            },
            prefixIdentityProvider: {
                try WindowsExecutablePrefixObjectIdentity(capturing: $0)
            }
        )

        let result = try await service.launch(
            runtimeExecutable: runtime,
            executable: executable
        )

        XCTAssertEqual(result.outcome, .runningDetached)
        XCTAssertEqual(owner.retainedLeaseCount, 1)
        XCTAssertFalse(events.contains("lease-release"))
        XCTAssertEqual(
            Array(events.suffix(3)),
            ["lifecycle-end", "root-release", "reservation-release"]
        )

        await waitForProbeCalls(probe, atLeast: 1)
        await probe.resumeNext(.failed)
        await waitForProbeCalls(probe, atLeast: 2)
        XCTAssertEqual(owner.retainedLeaseCount, 1)
        XCTAssertFalse(events.contains("lease-release"))

        await probe.resumeNext(.active)
        await waitForProbeCalls(probe, atLeast: 3)
        XCTAssertEqual(owner.retainedLeaseCount, 1)
        XCTAssertFalse(events.contains("lease-release"))

        let preservedPrefix = fixtureRoot.appending(
            path: "SteamShared-preserved",
            directoryHint: .isDirectory
        )
        try FileManager.default.moveItem(at: prefix, to: preservedPrefix)
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        await probe.resumeNext(.inactive)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(owner.retainedLeaseCount, 1)
        XCTAssertFalse(events.contains("lease-release"))

        try FileManager.default.removeItem(at: prefix)
        try FileManager.default.moveItem(at: preservedPrefix, to: prefix)
        await waitForProbeCalls(probe, atLeast: 4)
        await probe.resumeNext(.inactive)
        for _ in 0..<2_000 where owner.retainedLeaseCount != 0 {
            await Task.yield()
        }
        XCTAssertEqual(owner.retainedLeaseCount, 0)
        XCTAssertEqual(events.filter { $0 == "lease-release" }.count, 1)
    }

    private func waitForProbeCalls(
        _ probe: PrefixInactivityProbe,
        atLeast expectedCount: Int
    ) async {
        for _ in 0..<2_000 {
            if await probe.callCount >= expectedCount { return }
            await Task.yield()
        }
        XCTFail("Prefix inactivity probe did not reach call \(expectedCount)")
    }

    func testValidationFailureNeverTransitionsOrLaunchesAndCleansOwnership() async {
        enum Expected: Error { case incompatible }

        let prefix = URL(fileURLWithPath: "/tmp/ForgePlay/SteamShared")
        var events: [String] = []
        let reservation = WindowsExecutableLaunchReservation(id: UUID())
        let service = WindowsExecutableLaunchService(
            reservationProvider: {
                events.append("reservation")
                return reservation
            },
            reservationReleaser: { receivedReservation in
                XCTAssertEqual(receivedReservation, reservation)
                events.append("reservation-release")
            },
            prefixURLProvider: { prefix },
            runtimeCompatibilityValidator: { _ in
                events.append("runtime")
                throw Expected.incompatible
            },
            registerLifecycle: { _ in events.append("lifecycle-begin") },
            lifecycleCheckpoint: { events.append("checkpoint") },
            unregisterLifecycle: { _ in events.append("lifecycle-end") },
            managedRootLeaseProvider: {
                events.append("root-lease")
                return [
                    ManagedRootLease {
                        events.append("root-release")
                    }
                ]
            },
            leaseProvider: { _ in
                events.append("lease")
                return Lease(
                    onTransition: { events.append("shared") },
                    onRelease: { events.append("release") }
                )
            },
            usablePrefixValidator: { _ in events.append("usable") },
            rendererCapabilityValidator: { _, _, _ in
                events.append("renderer")
                return nil
            },
            launcher: { _, _, _, _, _, _, _ in
                events.append("launch")
                throw Expected.incompatible
            }
        )

        do {
            _ = try await service.launch(
                runtimeExecutable: URL(fileURLWithPath: "/tmp/ForgePlay/wine"),
                executable: URL(fileURLWithPath: "/tmp/ForgePlay/Tool.exe")
            )
            XCTFail("Expected runtime compatibility validation to fail")
        } catch Expected.incompatible {
            XCTAssertEqual(
                events,
                [
                    "reservation",
                    "root-lease",
                    "lifecycle-begin",
                    "lease",
                    "checkpoint",
                    "usable",
                    "runtime",
                    "release",
                    "lifecycle-end",
                    "root-release",
                    "reservation-release"
                ]
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFinalRendererRevalidationFailureCleansSharedOwnership()
        async
    {
        enum Expected: Error { case rendererUnavailable }

        let reservation = WindowsExecutableLaunchReservation(id: UUID())
        let prefix = URL(fileURLWithPath: "/tmp/ForgePlay/SteamShared")
        let runtime = URL(fileURLWithPath: "/tmp/ForgePlay/wine")
        var events: [String] = []
        let service = WindowsExecutableLaunchService(
            reservationProvider: {
                events.append("reservation")
                return reservation
            },
            reservationReleaser: { received in
                XCTAssertEqual(received, reservation)
                events.append("reservation-release")
            },
            prefixURLProvider: { prefix },
            runtimeCompatibilityValidator: { receivedRuntime in
                XCTAssertEqual(receivedRuntime, runtime)
                events.append("runtime")
            },
            registerLifecycle: { _ in events.append("lifecycle-begin") },
            lifecycleCheckpoint: { events.append("checkpoint") },
            unregisterLifecycle: { _ in events.append("lifecycle-end") },
            managedRootLeaseProvider: {
                events.append("root-lease")
                return [ManagedRootLease { events.append("root-release") }]
            },
            leaseProvider: { _ in
                events.append("lease")
                return Lease(
                    onTransition: { events.append("shared") },
                    onRelease: { events.append("release") }
                )
            },
            usablePrefixValidator: { _ in events.append("usable") },
            rendererCapabilityValidator: { receivedRuntime, _, renderer in
                XCTAssertEqual(receivedRuntime, runtime)
                XCTAssertEqual(renderer, .vulkan)
                events.append("renderer")
                throw Expected.rendererUnavailable
            },
            launcher: { _, _, _, _, _, _, _ in
                events.append("launch")
                throw Expected.rendererUnavailable
            }
        )

        do {
            _ = try await service.launch(
                runtimeExecutable: runtime,
                executable: URL(fileURLWithPath: "/tmp/ForgePlay/Tool.exe"),
                rendererPolicy: .vulkan
            )
            XCTFail("Expected renderer capability revalidation to fail")
        } catch Expected.rendererUnavailable {
            XCTAssertEqual(
                events,
                [
                    "reservation",
                    "root-lease",
                    "lifecycle-begin",
                    "lease",
                    "checkpoint",
                    "usable",
                    "runtime",
                    "checkpoint",
                    "shared",
                    "checkpoint",
                    "renderer",
                    "release",
                    "lifecycle-end",
                    "root-release",
                    "reservation-release"
                ]
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationDuringFinalRendererRevalidationCleansSharedOwnership()
        async
    {
        let reservation = WindowsExecutableLaunchReservation(id: UUID())
        let prefix = URL(fileURLWithPath: "/tmp/ForgePlay/SteamShared")
        var events: [String] = []
        let service = WindowsExecutableLaunchService(
            reservationProvider: {
                events.append("reservation")
                return reservation
            },
            reservationReleaser: { _ in events.append("reservation-release") },
            prefixURLProvider: { prefix },
            runtimeCompatibilityValidator: { _ in events.append("runtime") },
            registerLifecycle: { _ in events.append("lifecycle-begin") },
            lifecycleCheckpoint: { events.append("checkpoint") },
            unregisterLifecycle: { _ in events.append("lifecycle-end") },
            managedRootLeaseProvider: {
                events.append("root-lease")
                return [ManagedRootLease { events.append("root-release") }]
            },
            leaseProvider: { _ in
                events.append("lease")
                return Lease(
                    onTransition: { events.append("shared") },
                    onRelease: { events.append("release") }
                )
            },
            usablePrefixValidator: { _ in events.append("usable") },
            rendererCapabilityValidator: { _, _, _ in
                events.append("renderer")
                try await Task.sleep(for: .seconds(60))
                return nil
            },
            launcher: { _, _, _, _, _, _, _ in
                events.append("launch")
                throw CancellationError()
            }
        )

        let task = Task { @MainActor in
            try await service.launch(
                runtimeExecutable: URL(fileURLWithPath: "/tmp/ForgePlay/wine"),
                executable: URL(fileURLWithPath: "/tmp/ForgePlay/Tool.exe"),
                rendererPolicy: .d3dMetal
            )
        }
        for _ in 0..<2_000 {
            if events.contains("renderer") { break }
            await Task.yield()
        }
        XCTAssertTrue(events.contains("renderer"))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected renderer revalidation cancellation")
        } catch is CancellationError {
            XCTAssertEqual(
                events,
                [
                    "reservation",
                    "root-lease",
                    "lifecycle-begin",
                    "lease",
                    "checkpoint",
                    "usable",
                    "runtime",
                    "checkpoint",
                    "shared",
                    "checkpoint",
                    "renderer",
                    "release",
                    "lifecycle-end",
                    "root-release",
                    "reservation-release"
                ]
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReservationFailureOccursBeforeEveryOtherLaunchSideEffect() async {
        enum Expected: Error { case reservationUnavailable }
        var events: [String] = []
        let service = WindowsExecutableLaunchService(
            reservationProvider: {
                events.append("reservation")
                throw Expected.reservationUnavailable
            },
            reservationReleaser: { _ in events.append("reservation-release") },
            prefixURLProvider: {
                events.append("prefix")
                return URL(fileURLWithPath: "/tmp/ForgePlay/SteamShared")
            },
            runtimeCompatibilityValidator: { _ in events.append("runtime") },
            registerLifecycle: { _ in events.append("lifecycle-begin") },
            lifecycleCheckpoint: { events.append("checkpoint") },
            unregisterLifecycle: { _ in events.append("lifecycle-end") },
            managedRootLeaseProvider: {
                events.append("root-lease")
                return []
            },
            leaseProvider: { _ in
                events.append("lease")
                return Lease(onTransition: {}, onRelease: {})
            },
            usablePrefixValidator: { _ in events.append("usable") },
            rendererCapabilityValidator: { _, _, _ in
                events.append("renderer")
                return nil
            },
            launcher: { _, _, _, _, _, _, _ in
                events.append("launch")
                throw Expected.reservationUnavailable
            }
        )

        do {
            _ = try await service.launch(
                runtimeExecutable: URL(fileURLWithPath: "/tmp/ForgePlay/wine"),
                executable: URL(fileURLWithPath: "/tmp/ForgePlay/Tool.exe")
            )
            XCTFail("Expected reservation acquisition to fail")
        } catch Expected.reservationUnavailable {
            XCTAssertEqual(events, ["reservation"])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPreCancelledLaunchReservesThenReleasesWithoutOtherSideEffects() async {
        let reservation = WindowsExecutableLaunchReservation(id: UUID())
        var events: [String] = []
        let service = WindowsExecutableLaunchService(
            reservationProvider: {
                events.append("reservation")
                return reservation
            },
            reservationReleaser: { received in
                XCTAssertEqual(received, reservation)
                events.append("reservation-release")
            },
            prefixURLProvider: {
                events.append("prefix")
                return URL(fileURLWithPath: "/tmp/ForgePlay/SteamShared")
            },
            runtimeCompatibilityValidator: { _ in events.append("runtime") },
            registerLifecycle: { _ in events.append("lifecycle-begin") },
            lifecycleCheckpoint: { events.append("checkpoint") },
            unregisterLifecycle: { _ in events.append("lifecycle-end") },
            managedRootLeaseProvider: {
                events.append("root-lease")
                return [ManagedRootLease { events.append("root-release") }]
            },
            leaseProvider: { _ in
                events.append("lease")
                return Lease(
                    onTransition: { events.append("shared") },
                    onRelease: { events.append("release") }
                )
            },
            usablePrefixValidator: { _ in events.append("usable") },
            rendererCapabilityValidator: { _, _, _ in
                events.append("renderer")
                return nil
            },
            launcher: { _, _, _, _, _, _, _ in
                events.append("launch")
                throw CancellationError()
            }
        )

        let task = Task { @MainActor in
            try await service.launch(
                runtimeExecutable: URL(fileURLWithPath: "/tmp/ForgePlay/wine"),
                executable: URL(fileURLWithPath: "/tmp/ForgePlay/Tool.exe")
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(events, ["reservation", "reservation-release"])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLateCancellationAfterRendererOrSharedTransitionNeverLaunchesAndCleansLIFO()
        async
    {
        enum CancellationPhase {
            case rendererRevalidation
            case afterSharedTransition
        }

        for phase in [
            CancellationPhase.rendererRevalidation,
            .afterSharedTransition
        ] {
            let reservation = WindowsExecutableLaunchReservation(id: UUID())
            var events: [String] = []
            var checkpointCount = 0
            let service = WindowsExecutableLaunchService(
                reservationProvider: {
                    events.append("reservation")
                    return reservation
                },
                reservationReleaser: { received in
                    XCTAssertEqual(received, reservation)
                    events.append("reservation-release")
                },
                prefixURLProvider: {
                    URL(fileURLWithPath: "/tmp/ForgePlay/SteamShared")
                },
                runtimeCompatibilityValidator: { _ in events.append("runtime") },
                registerLifecycle: { _ in events.append("lifecycle-begin") },
                lifecycleCheckpoint: {
                    checkpointCount += 1
                    events.append("checkpoint-\(checkpointCount)")
                    if phase == .afterSharedTransition,
                       checkpointCount == 3 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                },
                unregisterLifecycle: { _ in events.append("lifecycle-end") },
                managedRootLeaseProvider: {
                    events.append("root-lease")
                    return [ManagedRootLease { events.append("root-release") }]
                },
                leaseProvider: { _ in
                    events.append("lease")
                    return Lease(
                        onTransition: { events.append("shared") },
                        onRelease: { events.append("release") }
                    )
                },
                usablePrefixValidator: { _ in events.append("usable") },
                rendererCapabilityValidator: { _, _, _ in
                    events.append("renderer")
                    if phase == .rendererRevalidation {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    return nil
                },
                launcher: { _, _, _, _, _, _, _ in
                    events.append("launch")
                    throw CancellationError()
                }
            )

            let task = Task { @MainActor in
                try await service.launch(
                    runtimeExecutable: URL(fileURLWithPath: "/tmp/ForgePlay/wine"),
                    executable: URL(fileURLWithPath: "/tmp/ForgePlay/Tool.exe"),
                    rendererPolicy: .vulkan
                )
            }

            do {
                _ = try await task.value
                XCTFail("Expected cancellation for \(phase)")
            } catch is CancellationError {
                XCTAssertFalse(events.contains("launch"))
                XCTAssertEqual(
                    Array(events.suffix(4)),
                    [
                        "release",
                        "lifecycle-end",
                        "root-release",
                        "reservation-release"
                    ]
                )
                if phase == .afterSharedTransition {
                    XCTAssertTrue(events.contains("shared"))
                    XCTAssertTrue(events.contains("checkpoint-3"))
                    XCTAssertFalse(events.contains("renderer"))
                } else {
                    XCTAssertTrue(events.contains("shared"))
                    XCTAssertTrue(events.contains("renderer"))
                    XCTAssertEqual(checkpointCount, 3)
                }
            } catch {
                XCTFail("Unexpected error for \(phase): \(error)")
            }
        }
    }

    func testManagedRootFailureReleasesReservationWithoutLaterSideEffects() async {
        enum Expected: Error { case rootUnavailable }
        let reservation = WindowsExecutableLaunchReservation(id: UUID())
        var events: [String] = []
        let service = WindowsExecutableLaunchService(
            reservationProvider: {
                events.append("reservation")
                return reservation
            },
            reservationReleaser: { received in
                XCTAssertEqual(received, reservation)
                events.append("reservation-release")
            },
            prefixURLProvider: {
                events.append("prefix")
                return URL(fileURLWithPath: "/tmp/ForgePlay/SteamShared")
            },
            runtimeCompatibilityValidator: { _ in events.append("runtime") },
            registerLifecycle: { _ in events.append("lifecycle-begin") },
            lifecycleCheckpoint: { events.append("checkpoint") },
            unregisterLifecycle: { _ in events.append("lifecycle-end") },
            managedRootLeaseProvider: {
                events.append("root-lease")
                throw Expected.rootUnavailable
            },
            leaseProvider: { _ in
                events.append("lease")
                return Lease(onTransition: {}, onRelease: {})
            },
            usablePrefixValidator: { _ in events.append("usable") },
            rendererCapabilityValidator: { _, _, _ in
                events.append("renderer")
                return nil
            },
            launcher: { _, _, _, _, _, _, _ in
                events.append("launch")
                throw Expected.rootUnavailable
            }
        )

        do {
            _ = try await service.launch(
                runtimeExecutable: URL(fileURLWithPath: "/tmp/ForgePlay/wine"),
                executable: URL(fileURLWithPath: "/tmp/ForgePlay/Tool.exe")
            )
            XCTFail("Expected managed-root acquisition to fail")
        } catch Expected.rootUnavailable {
            XCTAssertEqual(
                events,
                ["reservation", "root-lease", "reservation-release"]
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationReleasesReservationLastAfterAllLaunchOwnership() async {
        let reservation = WindowsExecutableLaunchReservation(id: UUID())
        let prefix = URL(fileURLWithPath: "/tmp/ForgePlay/SteamShared")
        var events: [String] = []
        let service = WindowsExecutableLaunchService(
            reservationProvider: {
                events.append("reservation")
                return reservation
            },
            reservationReleaser: { _ in events.append("reservation-release") },
            prefixURLProvider: { prefix },
            runtimeCompatibilityValidator: { _ in events.append("runtime") },
            registerLifecycle: { _ in events.append("lifecycle-begin") },
            lifecycleCheckpoint: { events.append("checkpoint") },
            unregisterLifecycle: { _ in events.append("lifecycle-end") },
            managedRootLeaseProvider: {
                events.append("root-lease")
                return [ManagedRootLease { events.append("root-release") }]
            },
            leaseProvider: { _ in
                events.append("lease")
                return Lease(
                    onTransition: { events.append("shared") },
                    onRelease: { events.append("release") }
                )
            },
            usablePrefixValidator: { _ in events.append("usable") },
            rendererCapabilityValidator: { _, _, _ in
                events.append("renderer")
                return nil
            },
            launcher: { _, _, _, _, _, _, _ in
                events.append("launch")
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }
        )

        let task = Task { @MainActor in
            try await service.launch(
                runtimeExecutable: URL(fileURLWithPath: "/tmp/ForgePlay/wine"),
                executable: URL(fileURLWithPath: "/tmp/ForgePlay/Tool.exe")
            )
        }
        for _ in 0..<1_000 {
            if events.contains("launch") { break }
            await Task.yield()
        }
        XCTAssertTrue(events.contains("launch"))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(
                Array(events.suffix(4)),
                [
                    "release",
                    "lifecycle-end",
                    "root-release",
                    "reservation-release"
                ]
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLaunchOwnedExternalRootScopeOutlivesSelectionReference() throws {
        let root = URL(fileURLWithPath: "/tmp/ForgePlay/External")
        var events: [String] = []
        let lease = try WindowsExecutableExternalRootAccessLease(
            root: root,
            requiresSecurityScope: true,
            startAccess: { receivedRoot in
                XCTAssertEqual(receivedRoot, root)
                events.append("launch-scope-start")
                return true
            },
            stopAccess: { receivedRoot in
                XCTAssertEqual(receivedRoot, root)
                events.append("launch-scope-stop")
            }
        )

        events.append("selection-scope-stop")
        XCTAssertEqual(lease.root, root)
        XCTAssertEqual(
            events,
            ["launch-scope-start", "selection-scope-stop"]
        )

        lease.release()
        lease.release()
        XCTAssertEqual(
            events,
            [
                "launch-scope-start",
                "selection-scope-stop",
                "launch-scope-stop"
            ]
        )
    }

    func testLaunchOwnedExternalRootScopeDoubleReleaseAndDeinitBalanceExactlyOnce()
        throws
    {
        let root = URL(fileURLWithPath: "/tmp/ForgePlay/External")
        var stopCount = 0
        var explicitLease: WindowsExecutableExternalRootAccessLease? =
            try WindowsExecutableExternalRootAccessLease(
                root: root,
                requiresSecurityScope: true,
                startAccess: { _ in true },
                stopAccess: { _ in stopCount += 1 }
            )
        explicitLease?.release()
        explicitLease?.release()
        explicitLease = nil
        XCTAssertEqual(stopCount, 1)

        var deinitLease: WindowsExecutableExternalRootAccessLease? =
            try WindowsExecutableExternalRootAccessLease(
                root: root,
                requiresSecurityScope: true,
                startAccess: { _ in true },
                stopAccess: { _ in stopCount += 1 }
            )
        XCTAssertNotNil(deinitLease)
        deinitLease = nil
        XCTAssertEqual(stopCount, 2)
    }

    func testLaunchOwnedExternalRootScopeFailsClosedWhenRequired() {
        let root = URL(fileURLWithPath: "/tmp/ForgePlay/External")

        XCTAssertThrowsError(
            try WindowsExecutableExternalRootAccessLease(
                root: root,
                requiresSecurityScope: true,
                startAccess: { _ in false }
            )
        ) { error in
            guard case WindowsExecutableExternalRootAccessError
                    .accessUnavailable(let rejectedRoot) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(rejectedRoot, root)
        }
    }

    func testRestoredStorageAccessOwnerOutlivesSuccessfulLaunchOperation()
        async
    {
        var probe: AccessLifetimeProbe? = AccessLifetimeProbe()
        weak let weakProbe = probe

        let result = await withWindowsExecutableLaunchAccessLifetime(probe!) {
            probe = nil
            await Task.yield()
            XCTAssertNotNil(weakProbe)
            return 42
        }

        XCTAssertEqual(result, 42)
        await Task.yield()
        XCTAssertNil(weakProbe)
    }

    func testRestoredStorageAccessOwnerOutlivesThrowingLaunchOperation() async {
        enum Expected: Error { case launchFailed }

        var probe: AccessLifetimeProbe? = AccessLifetimeProbe()
        weak let weakProbe = probe

        do {
            let _: Int = try await withWindowsExecutableLaunchAccessLifetime(probe!) {
                probe = nil
                await Task.yield()
                XCTAssertNotNil(weakProbe)
                throw Expected.launchFailed
            }
            XCTFail("Expected launch operation to throw")
        } catch Expected.launchFailed {
            await Task.yield()
            XCTAssertNil(weakProbe)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRestoredStorageAccessOwnerOutlivesCancelledLaunchOperation() async {
        var probe: AccessLifetimeProbe? = AccessLifetimeProbe()
        weak let weakProbe = probe
        var didEnterOperation = false

        let task: Task<Void, Error> = Task { @MainActor in
            try await withWindowsExecutableLaunchAccessLifetime(probe!) {
                probe = nil
                didEnterOperation = true
                while !Task.isCancelled {
                    await Task.yield()
                }
                XCTAssertNotNil(weakProbe)
                throw CancellationError()
            }
        }

        for _ in 0..<2_000 {
            if didEnterOperation { break }
            await Task.yield()
        }
        XCTAssertTrue(didEnterOperation)
        XCTAssertNotNil(weakProbe)
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected launch operation cancellation")
        } catch is CancellationError {
            await Task.yield()
            XCTAssertNil(weakProbe)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLaunchAvailabilityCombinesLaunchFilePersistedRuntimeRendererAndOwnership() {
        XCTAssertEqual(
            WindowsExecutableLaunchAvailability.resolve(
                isLaunching: true,
                hasSelectedExecutable: true,
                hasPersistedRuntime: true,
                rendererAvailability: nil,
                ownershipAvailability: .available
            ),
            .launchInProgress
        )
        XCTAssertEqual(
            WindowsExecutableLaunchAvailability.resolve(
                isLaunching: false,
                hasSelectedExecutable: false,
                hasPersistedRuntime: true,
                rendererAvailability: nil,
                ownershipAvailability: .available
            ),
            .executableNotSelected
        )
        XCTAssertEqual(
            WindowsExecutableLaunchAvailability.resolve(
                isLaunching: false,
                hasSelectedExecutable: true,
                hasPersistedRuntime: false,
                rendererAvailability: nil,
                ownershipAvailability: .available
            ),
            .persistedRuntimeNotSelected
        )
        XCTAssertEqual(
            WindowsExecutableLaunchAvailability.resolve(
                isLaunching: false,
                hasSelectedExecutable: true,
                hasPersistedRuntime: true,
                rendererAvailability: .rendererCapabilityPending,
                ownershipAvailability: .available
            ),
            .rendererCapabilityPending
        )
        XCTAssertEqual(
            WindowsExecutableLaunchAvailability.resolve(
                isLaunching: false,
                hasSelectedExecutable: true,
                hasPersistedRuntime: true,
                rendererAvailability: nil,
                ownershipAvailability: .blockedByPrefixLifecycle
            ),
            .ownershipUnavailable(.blockedByPrefixLifecycle)
        )
        let standardReservation = WindowsExecutableLaunchAvailability.resolve(
            isLaunching: false,
            hasSelectedExecutable: true,
            hasPersistedRuntime: true,
            rendererAvailability: nil,
            ownershipAvailability: .blockedByStandardSteamLaunch
        )
        XCTAssertEqual(
            standardReservation,
            .ownershipUnavailable(.blockedByStandardSteamLaunch)
        )
        XCTAssertEqual(
            standardReservation.reasonLocalizationKey,
            "일반 Steam 실행 준비가 끝날 때까지 기다리세요."
        )

        let publishedStates: [WindowsExecutableLaunchAvailability] = [
            .available,
            .launchInProgress,
            .executableNotSelected,
            .persistedRuntimeNotSelected,
            .rendererCapabilityPending,
            .rendererCapabilityUnavailable,
            .ownershipUnavailable(.blockedByCompatibilitySession),
            .ownershipUnavailable(.blockedByCompatibilityTransition),
            .ownershipUnavailable(.blockedByStandardSteamLaunch),
            .ownershipUnavailable(.blockedByWindowsExecutableLaunch),
            .ownershipUnavailable(.blockedByPrefixLifecycle),
        ]
        for state in publishedStates {
            XCTAssertEqual(state.isAvailable, state == .available)
            XCTAssertFalse(
                state.reasonLocalizationKey
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
        }
    }

    func testLaunchRequestSnapshotFreezesExecutableRuntimeBackendPolicyAndCapabilityKey() {
        let runtime = URL(fileURLWithPath: "/tmp/ForgePlay/../ForgePlay/wine")
        let executable = URL(fileURLWithPath: "/tmp/ForgePlay/Tools/../Tool.exe")
        var selectedBackend = WindowsExecutableRendererBackend.dxvk
        var environmentRevision = 17

        let snapshot = WindowsExecutableLaunchRequestSnapshot(
            runtimeExecutable: runtime,
            executable: executable,
            rendererBackend: selectedBackend,
            environmentRevision: environmentRevision
        )
        selectedBackend = .base
        environmentRevision = 18

        XCTAssertEqual(snapshot.runtimeExecutable, runtime.standardizedFileURL)
        XCTAssertEqual(snapshot.executable, executable.standardizedFileURL)
        XCTAssertEqual(snapshot.rendererBackend, .dxvk)
        XCTAssertEqual(snapshot.rendererPolicy, .vulkan)
        XCTAssertEqual(snapshot.environmentRevision, 17)
        XCTAssertEqual(
            snapshot.rendererCapabilityKey,
            WindowsExecutableRendererCapabilityKey(
                runtimeExecutable: runtime.standardizedFileURL,
                backend: .dxvk,
                environmentRevision: 17
            )
        )
        XCTAssertEqual(selectedBackend, .base)
        XCTAssertEqual(environmentRevision, 18)

        let baseSnapshot = WindowsExecutableLaunchRequestSnapshot(
            runtimeExecutable: runtime,
            executable: executable,
            rendererBackend: .base,
            environmentRevision: environmentRevision
        )
        XCTAssertNil(baseSnapshot.rendererPolicy)
        XCTAssertNil(baseSnapshot.rendererCapabilityKey)
        XCTAssertEqual(baseSnapshot.environmentRevision, 18)
    }

    func testRendererCapabilityStateBlocksPendingStaleAndUnavailableSnapshots() {
        let current = WindowsExecutableRendererCapabilityKey(
            runtimeExecutable: URL(fileURLWithPath: "/tmp/ForgePlay/wine-current"),
            backend: .dxvk,
            environmentRevision: 2
        )
        let stale = WindowsExecutableRendererCapabilityKey(
            runtimeExecutable: URL(fileURLWithPath: "/tmp/ForgePlay/wine-stale"),
            backend: .dxvk,
            environmentRevision: 1
        )

        XCTAssertNil(
            WindowsExecutableRendererCapabilityState.notRequired
                .launchAvailability(for: nil)
        )
        XCTAssertEqual(
            WindowsExecutableRendererCapabilityState.pending(current)
                .launchAvailability(for: current),
            .rendererCapabilityPending
        )
        XCTAssertEqual(
            WindowsExecutableRendererCapabilityState.satisfied(stale)
                .launchAvailability(for: current),
            .rendererCapabilityPending
        )
        XCTAssertEqual(
            WindowsExecutableRendererCapabilityState.unavailable(current)
                .launchAvailability(for: current),
            .rendererCapabilityUnavailable
        )
        XCTAssertNil(
            WindowsExecutableRendererCapabilityState.satisfied(current)
                .launchAvailability(for: current)
        )

        var state = WindowsExecutableRendererCapabilityState.satisfied(current)
        state.recordUnavailable(for: stale, whenCurrentKeyIs: current)
        XCTAssertEqual(state, .satisfied(current))
        state.recordUnavailable(for: current, whenCurrentKeyIs: current)
        XCTAssertEqual(state, .unavailable(current))
    }

    func testSameRuntimePathNewEnvironmentRevisionRequiresReinspection() {
        let runtime = URL(fileURLWithPath: "/tmp/ForgePlay/wine")
        let revisionOne = WindowsExecutableRendererCapabilityKey(
            runtimeExecutable: runtime,
            backend: .dxvk,
            environmentRevision: 1
        )
        let revisionTwo = WindowsExecutableRendererCapabilityKey(
            runtimeExecutable: runtime,
            backend: .dxvk,
            environmentRevision: 2
        )

        XCTAssertEqual(
            WindowsExecutableRendererCapabilityState.satisfied(revisionOne)
                .launchAvailability(for: revisionTwo),
            .rendererCapabilityPending
        )
        XCTAssertEqual(
            WindowsExecutableRendererCapabilityState.unavailable(revisionOne)
                .launchAvailability(for: revisionTwo),
            .rendererCapabilityPending
        )
        XCTAssertNil(
            WindowsExecutableRendererCapabilityState.satisfied(revisionTwo)
                .launchAvailability(for: revisionTwo)
        )
        XCTAssertEqual(
            WindowsExecutableRendererCapabilityState.unavailable(revisionTwo)
                .launchAvailability(for: revisionTwo),
            .rendererCapabilityUnavailable
        )
    }

    func testConfirmedPrefixShutdownSynchronouslyReleasesAllMatchingDetachedLeases()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayDetachedLeaseBarrier-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let prefix = root.appending(path: "SteamShared", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)

        let owner = WindowsExecutablePrefixExecutionLifetimeOwner(
            retryDelay: { _ in try? await Task.sleep(for: .seconds(60)) }
        )
        var releaseCount = 0
        for _ in 0..<2 {
            owner.retain(
                Lease(onTransition: {}, onRelease: { releaseCount += 1 }),
                prefixIdentity: try WindowsExecutablePrefixObjectIdentity(
                    capturing: prefix
                ),
                inactivityWaiter: { _, _, _ in false }
            )
        }
        XCTAssertEqual(owner.retainedLeaseCount, 2)

        try await owner.completeAfterConfirmedPrefixShutdown(
            prefix: prefix,
            inactivityWaiter: { _, _, _ in true }
        )

        XCTAssertEqual(owner.retainedLeaseCount, 0)
        XCTAssertEqual(releaseCount, 2)
        let mutationLease = try PrefixExecutionLease.acquireExclusiveMutation(
            forPrefix: prefix
        )
        mutationLease.release()
    }

    func testUnconfirmedOrReplacedPrefixRetainsDetachedLease() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayDetachedLeaseFailClosed-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let prefix = root.appending(path: "SteamShared", directoryHint: .isDirectory)
        let preserved = root.appending(path: "SteamShared-preserved", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)

        let owner = WindowsExecutablePrefixExecutionLifetimeOwner(
            retryDelay: { _ in try? await Task.sleep(for: .seconds(60)) }
        )
        var releaseCount = 0
        owner.retain(
            Lease(onTransition: {}, onRelease: { releaseCount += 1 }),
            prefixIdentity: try WindowsExecutablePrefixObjectIdentity(capturing: prefix),
            inactivityWaiter: { _, _, _ in false }
        )

        do {
            try await owner.completeAfterConfirmedPrefixShutdown(
                prefix: prefix,
                inactivityWaiter: { _, _, _ in false }
            )
            XCTFail("Expected an unconfirmed prefix to retain its lease")
        } catch {}
        XCTAssertEqual(owner.retainedLeaseCount, 1)
        XCTAssertEqual(releaseCount, 0)

        try FileManager.default.moveItem(at: prefix, to: preserved)
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        do {
            try await owner.completeAfterConfirmedPrefixShutdown(
                prefix: prefix,
                inactivityWaiter: { _, _, _ in true }
            )
            XCTFail("Expected a replaced prefix object to retain its lease")
        } catch {}
        XCTAssertEqual(owner.retainedLeaseCount, 1)
        XCTAssertEqual(releaseCount, 0)
    }

    func testNavigationStableRendererInspectionOwnerSerializesConcurrentRequests()
        async
    {
        let probe = InspectionConcurrencyProbe()
        let inspector = WindowsExecutableRendererCapabilityInspector(
            inspection: { key, _ in probe.inspect(key) }
        )
        let firstCoordinator =
            WindowsExecutableRendererCapabilityInspectionCoordinator(
                inspector: inspector
            )
        let secondCoordinator =
            WindowsExecutableRendererCapabilityInspectionCoordinator(
                inspector: inspector
            )
        let firstKey = WindowsExecutableRendererCapabilityKey(
            runtimeExecutable: URL(fileURLWithPath: "/tmp/ForgePlay/wine-a"),
            backend: .dxvk,
            environmentRevision: 1
        )
        let secondKey = WindowsExecutableRendererCapabilityKey(
            runtimeExecutable: URL(fileURLWithPath: "/tmp/ForgePlay/wine-b"),
            backend: .d3dMetal,
            environmentRevision: 2
        )
        let capability = WindowsRuntimeCapability(
            executableURL: firstKey.runtimeExecutable,
            graphicsBackend: .moltenVKOrVulkan,
            evidence: ["test-capability"],
            limitations: []
        )

        async let first = firstCoordinator.inspect(
            firstKey,
            capability: capability
        )
        async let second = secondCoordinator.inspect(
            secondKey,
            capability: capability
        )
        let results = await (first, second)

        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1)
        XCTAssertEqual(probe.maximumActiveCount, 1)
    }

}
