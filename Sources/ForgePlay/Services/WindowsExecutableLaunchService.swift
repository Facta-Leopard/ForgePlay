import Darwin
import Foundation

protocol WindowsExecutableLaunchLease: AnyObject {
    func transitionToSharedExecution() throws
    func release()
}

extension PrefixExecutionLease: WindowsExecutableLaunchLease {}

protocol WindowsExecutableManagedRootLease {
    func release()
}

extension ManagedRootOperationLease: WindowsExecutableManagedRootLease {}

struct WindowsExecutablePrefixObjectIdentity: Hashable, Sendable {
    let prefix: URL
    let device: UInt64
    let inode: UInt64

    init(capturing prefix: URL) throws {
        let normalized = prefix.standardizedFileURL
        var status = stat()
        guard lstat(normalized.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw WindowsExecutableLaunchServiceError
                .unusableSharedPrefix(normalized)
        }
        self.prefix = normalized
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
    }

    func isCurrent() -> Bool {
        var status = stat()
        return lstat(prefix.path, &status) == 0 &&
            (status.st_mode & S_IFMT) == S_IFDIR &&
            UInt64(status.st_dev) == device &&
            UInt64(status.st_ino) == inode
    }
}

/// Retains the shared prefix lock after the short-lived Wine launcher has
/// detached. The lock is released only after the managed-process journal
/// proves that the exact prefix object is inactive. Readback failures retain
/// ownership and retry; they never turn uncertainty into mutation admission.
@MainActor
final class WindowsExecutablePrefixExecutionLifetimeOwner {
    typealias PrefixInactivityWaiter = @Sendable (
        _ prefix: URL,
        _ timeout: TimeInterval,
        _ pollInterval: TimeInterval
    ) async throws -> Bool
    typealias RetryDelay = @MainActor @Sendable (_ failureCount: Int) async -> Void

    static let shared = WindowsExecutablePrefixExecutionLifetimeOwner()

    private struct RetainedLease {
        let lease: any WindowsExecutableLaunchLease
        let prefixIdentity: WindowsExecutablePrefixObjectIdentity?
        var monitor: Task<Void, Never>?
    }

    private let retryDelay: RetryDelay
    private var retainedLeases: [UUID: RetainedLease] = [:]

    init(
        retryDelay: @escaping RetryDelay = { failureCount in
            let exponent = min(max(failureCount - 1, 0), 6)
            try? await Task.sleep(for: .seconds(min(60, 1 << exponent)))
        }
    ) {
        self.retryDelay = retryDelay
    }

    func retain(
        _ lease: any WindowsExecutableLaunchLease,
        prefixIdentity: WindowsExecutablePrefixObjectIdentity?,
        inactivityWaiter: @escaping PrefixInactivityWaiter
    ) {
        let identifier = UUID()
        retainedLeases[identifier] = RetainedLease(
            lease: lease,
            prefixIdentity: prefixIdentity,
            monitor: nil
        )
        guard let prefixIdentity else {
            // This is available only to injected test seams. Production
            // captures identity before dispatch. Missing identity must still
            // retain the lock rather than release an active detached child.
            return
        }
        let monitor = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.monitor(
                identifier: identifier,
                prefixIdentity: prefixIdentity,
                inactivityWaiter: inactivityWaiter
            )
        }
        retainedLeases[identifier]?.monitor = monitor
    }

    var retainedLeaseCount: Int { retainedLeases.count }

    /// Completes the same shared-execution ownership after the caller has
    /// proved the exact prefix inactive. App termination and managed-root
    /// replacement use this synchronous barrier before attempting an
    /// exclusive mutation lease, eliminating the monitor-release race.
    func completeAfterConfirmedPrefixShutdown(
        prefix: URL,
        inactivityWaiter: @escaping PrefixInactivityWaiter
    ) async throws {
        let currentIdentity = try WindowsExecutablePrefixObjectIdentity(
            capturing: prefix
        )
        let retainedForPath = retainedLeases.filter { _, retained in
            retained.prefixIdentity?.prefix.standardizedFileURL.path ==
                currentIdentity.prefix.standardizedFileURL.path
        }
        guard !retainedForPath.isEmpty else { return }
        guard retainedForPath.values.allSatisfy({
            $0.prefixIdentity == currentIdentity
        }) else {
            throw WindowsExecutableLaunchServiceError
                .prefixShutdownNotConfirmed(currentIdentity.prefix)
        }
        guard currentIdentity.isCurrent(),
              try await inactivityWaiter(currentIdentity.prefix, 5, 0.2),
              currentIdentity.isCurrent() else {
            throw WindowsExecutableLaunchServiceError
                .prefixShutdownNotConfirmed(currentIdentity.prefix)
        }
        for identifier in retainedForPath.keys {
            release(identifier: identifier)
        }
    }

    private func monitor(
        identifier: UUID,
        prefixIdentity: WindowsExecutablePrefixObjectIdentity,
        inactivityWaiter: @escaping PrefixInactivityWaiter
    ) async {
        var failureCount = 0
        while !Task.isCancelled,
              retainedLeases[identifier] != nil {
            do {
                guard prefixIdentity.isCurrent() else {
                    failureCount = Self.nextFailureCount(failureCount)
                    await retryDelay(failureCount)
                    continue
                }
                let isInactive = try await inactivityWaiter(
                    prefixIdentity.prefix,
                    5,
                    0.2
                )
                guard isInactive, prefixIdentity.isCurrent() else {
                    failureCount = Self.nextFailureCount(failureCount)
                    await retryDelay(failureCount)
                    continue
                }
                release(identifier: identifier)
                return
            } catch {
                failureCount = Self.nextFailureCount(failureCount)
                await retryDelay(failureCount)
            }
        }
    }

    private nonisolated static func nextFailureCount(_ current: Int) -> Int {
        min(max(current, 0), 63) + 1
    }

    private func release(identifier: UUID) {
        guard let retained = retainedLeases.removeValue(
            forKey: identifier
        ) else {
            return
        }
        retained.monitor?.cancel()
        retained.lease.release()
    }

    isolated deinit {
        retainedLeases.values.forEach {
            $0.monitor?.cancel()
            $0.lease.release()
        }
    }
}

enum WindowsExecutableLaunchServiceError: LocalizedError {
    case unusableSharedPrefix(URL)
    case rendererCapabilityUnavailable
    case prefixShutdownNotConfirmed(URL)

    var errorDescription: String? {
        switch self {
        case .unusableSharedPrefix(let prefix):
            "SteamShared 프리픽스를 사용할 수 없습니다: \(prefix.path)"
        case .rendererCapabilityUnavailable:
            "선택한 그래픽 백엔드를 현재 ForgePlay Runtime에서 사용할 수 없습니다."
        case .prefixShutdownNotConfirmed(let prefix):
            "실행 중인 Windows 프로세스 종료를 확인하지 못했습니다: \(prefix.path)"
        }
    }
}

/// Owns the direct external-EXE transaction without importing Steam game
/// policy. The same shared Steam prefix, lifecycle coordinator, and execution
/// lease are used by AppServices; no parallel prefix ownership is created.
@MainActor
final class WindowsExecutableLaunchService {
    typealias ReservationProvider = () throws -> WindowsExecutableLaunchReservation
    typealias ReservationReleaser = (WindowsExecutableLaunchReservation) -> Void
    typealias PrefixURLProvider = () throws -> URL
    typealias RuntimeCompatibilityValidator = (URL) throws -> Void
    typealias LifecycleRegistration = (URL) throws -> Void
    typealias LifecycleCheckpoint = () throws -> Void
    typealias LifecycleUnregistration = (URL) -> Void
    typealias ManagedRootLeaseProvider =
        () throws -> [any WindowsExecutableManagedRootLease]
    typealias LeaseProvider = (URL) throws -> any WindowsExecutableLaunchLease
    typealias UsablePrefixValidator = (URL) throws -> Void
    typealias RendererCapabilityValidator = @MainActor (
        _ runtimeExecutable: URL,
        _ prefix: URL,
        _ rendererPolicy: SteamRendererPolicyPreference?
    ) async throws -> WindowsRuntimeCapability?
    typealias Launcher = (
        _ runtimeExecutable: URL,
        _ prefix: URL,
        _ executable: URL,
        _ arguments: [String],
        _ rendererPolicy: SteamRendererPolicyPreference?,
        _ runtimeCapability: WindowsRuntimeCapability?,
        _ externalStorageRoots: [URL]
    ) async throws -> ProcessRunResult
    typealias PrefixInactivityWaiter =
        WindowsExecutablePrefixExecutionLifetimeOwner.PrefixInactivityWaiter
    typealias PrefixIdentityProvider =
        (_ prefix: URL) throws -> WindowsExecutablePrefixObjectIdentity?

    private let prefixURLProvider: PrefixURLProvider
    private let reservationProvider: ReservationProvider
    private let reservationReleaser: ReservationReleaser
    private let runtimeCompatibilityValidator: RuntimeCompatibilityValidator
    private let registerLifecycle: LifecycleRegistration
    private let lifecycleCheckpoint: LifecycleCheckpoint
    private let unregisterLifecycle: LifecycleUnregistration
    private let managedRootLeaseProvider: ManagedRootLeaseProvider
    private let leaseProvider: LeaseProvider
    private let usablePrefixValidator: UsablePrefixValidator
    private let rendererCapabilityValidator: RendererCapabilityValidator
    private let launcher: Launcher
    private let prefixExecutionLifetimeOwner:
        WindowsExecutablePrefixExecutionLifetimeOwner
    private let prefixInactivityWaiter: PrefixInactivityWaiter
    private let prefixIdentityProvider: PrefixIdentityProvider

    init(
        windowsRuntimeService: WindowsRuntimeService,
        prefixManager: PrefixManager,
        steamManager: SteamManager,
        safeProcessRunner: SafeProcessRunner,
        lifecycleCoordinator: SteamPrefixLifecycleCoordinator,
        compatibilityCoordinator: SteamCompatibilitySessionCoordinator,
        fileManager: FileManager = .default,
        prefixExecutionLifetimeOwner:
            WindowsExecutablePrefixExecutionLifetimeOwner = .shared
    ) {
        reservationProvider = {
            try compatibilityCoordinator.reserveWindowsExecutableLaunch(
                prefixLifecycleIsBusy: lifecycleCoordinator.isBusy
            )
        }
        reservationReleaser = { reservation in
            compatibilityCoordinator
                .releaseWindowsExecutableLaunchReservation(reservation)
        }
        prefixURLProvider = {
            try prefixManager.steamSharedPrefixURL()
        }
        runtimeCompatibilityValidator = { runtimeExecutable in
            try prefixManager.requireSteamSharedPrefixRuntimeCompatibility(
                runtimeExecutable: runtimeExecutable
            )
        }
        registerLifecycle = { prefix in
            try lifecycleCoordinator.registerManagedPrefix(prefix)
        }
        lifecycleCheckpoint = {
            try lifecycleCoordinator.checkpoint()
        }
        unregisterLifecycle = { prefix in
            lifecycleCoordinator.unregisterManagedPrefix(prefix)
        }
        managedRootLeaseProvider = {
            try prefixManager.acquireManagedRootOperationLease().map {
                $0 as any WindowsExecutableManagedRootLease
            }
        }
        leaseProvider = { prefix in
            try PrefixExecutionLease.acquireExclusiveMutation(
                forPrefix: prefix,
                fileManager: fileManager
            )
        }
        usablePrefixValidator = { prefix in
            guard prefixManager.isUsablePrefix(at: prefix) else {
                throw WindowsExecutableLaunchServiceError
                    .unusableSharedPrefix(prefix)
            }
        }
        rendererCapabilityValidator = {
            runtimeExecutable,
            _,
            rendererPolicy in
            guard let rendererPolicy else { return nil }
            let snapshot = try await windowsRuntimeService
                .runtimeCapabilitySnapshot(executable: runtimeExecutable)
            let revalidated = try await windowsRuntimeService
                .revalidatedRuntimeCapabilitySnapshot(
                    snapshot,
                    executable: runtimeExecutable
                )
            guard rendererPolicy.isSatisfied(
                by: revalidated.capability
            ) else {
                throw WindowsExecutableLaunchServiceError
                    .rendererCapabilityUnavailable
            }
            return revalidated.capability
        }
        launcher = {
            runtimeExecutable,
            prefix,
            executable,
            arguments,
            rendererPolicy,
            runtimeCapability,
            externalStorageRoots in
            try await steamManager.launchWindowsUtility(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                executable: executable,
                arguments: arguments,
                rendererPolicy: rendererPolicy,
                runtimeCapability: runtimeCapability,
                externalStorageRoots: externalStorageRoots
            )
        }
        self.prefixExecutionLifetimeOwner = prefixExecutionLifetimeOwner
        prefixIdentityProvider = {
            try WindowsExecutablePrefixObjectIdentity(capturing: $0)
        }
        prefixInactivityWaiter = { prefix, timeout, pollInterval in
            try await safeProcessRunner.waitForManagedPrefixProcessesToExit(
                prefix,
                timeout: timeout,
                pollInterval: pollInterval
            )
        }
    }

    init(
        reservationProvider: @escaping ReservationProvider,
        reservationReleaser: @escaping ReservationReleaser,
        prefixURLProvider: @escaping PrefixURLProvider,
        runtimeCompatibilityValidator:
            @escaping RuntimeCompatibilityValidator,
        registerLifecycle: @escaping LifecycleRegistration,
        lifecycleCheckpoint: @escaping LifecycleCheckpoint,
        unregisterLifecycle: @escaping LifecycleUnregistration,
        managedRootLeaseProvider:
            @escaping ManagedRootLeaseProvider,
        leaseProvider: @escaping LeaseProvider,
        usablePrefixValidator: @escaping UsablePrefixValidator,
        rendererCapabilityValidator:
            @escaping RendererCapabilityValidator,
        launcher: @escaping Launcher,
        prefixExecutionLifetimeOwner:
            WindowsExecutablePrefixExecutionLifetimeOwner = .shared,
        prefixInactivityWaiter:
            @escaping PrefixInactivityWaiter = { _, _, _ in true },
        prefixIdentityProvider:
            @escaping PrefixIdentityProvider = { _ in nil }
    ) {
        self.reservationProvider = reservationProvider
        self.reservationReleaser = reservationReleaser
        self.prefixURLProvider = prefixURLProvider
        self.runtimeCompatibilityValidator = runtimeCompatibilityValidator
        self.registerLifecycle = registerLifecycle
        self.lifecycleCheckpoint = lifecycleCheckpoint
        self.unregisterLifecycle = unregisterLifecycle
        self.managedRootLeaseProvider = managedRootLeaseProvider
        self.leaseProvider = leaseProvider
        self.usablePrefixValidator = usablePrefixValidator
        self.rendererCapabilityValidator = rendererCapabilityValidator
        self.launcher = launcher
        self.prefixExecutionLifetimeOwner = prefixExecutionLifetimeOwner
        self.prefixInactivityWaiter = prefixInactivityWaiter
        self.prefixIdentityProvider = prefixIdentityProvider
    }

    func launch(
        runtimeExecutable: URL,
        executable: URL,
        arguments: [String] = [],
        rendererPolicy: SteamRendererPolicyPreference? = nil,
        externalStorageRoots: [URL] = []
    ) async throws -> ProcessRunResult {
        let reservation = try reservationProvider()
        defer { reservationReleaser(reservation) }
        try Task.checkCancellation()

        let managedRootLeases = try managedRootLeaseProvider()
        defer {
            managedRootLeases.reversed().forEach { $0.release() }
        }

        let prefix = try prefixURLProvider().standardizedFileURL
        try registerLifecycle(prefix)
        defer { unregisterLifecycle(prefix) }

        let lease = try leaseProvider(prefix)
        var leaseWasTransferred = false
        defer {
            if !leaseWasTransferred {
                lease.release()
            }
        }

        try lifecycleCheckpoint()
        try usablePrefixValidator(prefix)
        try runtimeCompatibilityValidator(runtimeExecutable)
        try Task.checkCancellation()
        try lifecycleCheckpoint()
        try lease.transitionToSharedExecution()
        let prefixIdentity = try prefixIdentityProvider(prefix)
        try lifecycleCheckpoint()
        try Task.checkCancellation()
        let runtimeCapability = try await rendererCapabilityValidator(
            runtimeExecutable,
            prefix,
            rendererPolicy
        )
        try Task.checkCancellation()
        try lifecycleCheckpoint()

        do {
            let result = try await launcher(
                runtimeExecutable,
                prefix,
                executable,
                arguments,
                rendererPolicy,
                runtimeCapability,
                externalStorageRoots
            )
            if Self.requiresProcessLifetimeOwnership(result) {
                prefixExecutionLifetimeOwner.retain(
                    lease,
                    prefixIdentity: prefixIdentity,
                    inactivityWaiter: prefixInactivityWaiter
                )
                leaseWasTransferred = true
            }
            return result
        } catch {
            if diagnosticProcessRunResults(from: error).contains(
                where: Self.requiresProcessLifetimeOwnership
            ) {
                prefixExecutionLifetimeOwner.retain(
                    lease,
                    prefixIdentity: prefixIdentity,
                    inactivityWaiter: prefixInactivityWaiter
                )
                leaseWasTransferred = true
            }
            throw error
        }
    }

    private nonisolated static func requiresProcessLifetimeOwnership(
        _ result: ProcessRunResult
    ) -> Bool {
        result.outcome == .runningDetached &&
            !result.waitedForExit &&
            (result.processIdentifier ?? 0) > 0
    }
}
