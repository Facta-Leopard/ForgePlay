import AppKit
@preconcurrency import ApplicationServices
import Carbon
@preconcurrency import CoreGraphics
import Darwin
import Foundation

enum GameInputModifierBinding: String, Hashable, Sendable {
    case control
    case alt
    case disabled
}

struct GameInputModifierMap: Hashable, Sendable {
    var command: GameInputModifierBinding
    var option: GameInputModifierBinding
    var control: GameInputModifierBinding

    static let recommended = GameInputModifierMap(
        command: .control,
        option: .alt,
        control: .control
    )

    init(
        command: GameInputModifierBinding,
        option: GameInputModifierBinding,
        control: GameInputModifierBinding
    ) {
        self.command = command
        self.option = option
        self.control = control
    }
}

struct GameInputProtectionPolicy: Hashable, Sendable {
    var modifierMap: GameInputModifierMap?
    var blockAppWindowManagementShortcuts: Bool
    var blockAppSwitchingShortcuts: Bool
    var blockMissionControlSpaceShortcuts: Bool
    var blockDefaultScreenshotShortcuts: Bool
    var hidePointerWhileManagedGameFrontmost: Bool

    static let disabled = GameInputProtectionPolicy()

    init(
        modifierMap: GameInputModifierMap? = nil,
        blockAppWindowManagementShortcuts: Bool = false,
        blockAppSwitchingShortcuts: Bool = false,
        blockMissionControlSpaceShortcuts: Bool = false,
        blockDefaultScreenshotShortcuts: Bool = false,
        hidePointerWhileManagedGameFrontmost: Bool = false
    ) {
        self.modifierMap = modifierMap
        self.blockAppWindowManagementShortcuts =
            blockAppWindowManagementShortcuts
        self.blockAppSwitchingShortcuts = blockAppSwitchingShortcuts
        self.blockMissionControlSpaceShortcuts =
            blockMissionControlSpaceShortcuts
        self.blockDefaultScreenshotShortcuts = blockDefaultScreenshotShortcuts
        self.hidePointerWhileManagedGameFrontmost =
            hidePointerWhileManagedGameFrontmost
    }

    var requiresEventTap: Bool {
        modifierMap != nil ||
            blockAppWindowManagementShortcuts ||
            blockAppSwitchingShortcuts ||
            blockMissionControlSpaceShortcuts ||
            blockDefaultScreenshotShortcuts
    }

    var requiresManagedTarget: Bool {
        requiresEventTap || hidePointerWhileManagedGameFrontmost
    }

    var isActive: Bool { requiresManagedTarget }
}

enum GameInputProtectionBuildCapability {
    /// The Developer ID DMG uses the public CGEventTap and TCC contracts even
    /// though the app itself remains sandboxed. When event-tap protection is
    /// enabled, launch admission still fails closed unless both permission
    /// preflight and tap enable readback pass. Unprotected launches do not
    /// require either permission.
    #if FORGEPLAY_APP_STORE
    static let isSupportedInCurrentBuild = false
    #else
    static let isSupportedInCurrentBuild = true
    #endif
}

/// The UI and launch coordinator share this store. Updates affect future
/// launch admissions; an admitted session keeps its immutable policy snapshot.
final class GameInputProtectionPolicyStore: @unchecked Sendable {
    private let lock = NSLock()
    private var policy: GameInputProtectionPolicy

    private let isSupported: Bool

    init(
        initialPolicy: GameInputProtectionPolicy = .disabled,
        isSupportedInCurrentBuild: Bool =
            GameInputProtectionBuildCapability.isSupportedInCurrentBuild
    ) {
        isSupported = isSupportedInCurrentBuild
        policy = isSupportedInCurrentBuild ? initialPolicy : .disabled
    }

    func snapshot() -> GameInputProtectionPolicy {
        lock.withLock { policy }
    }

    func update(_ policy: GameInputProtectionPolicy) {
        lock.withLock {
            self.policy = isSupported ? policy : .disabled
        }
    }

    func update(_ transform: (inout GameInputProtectionPolicy) -> Void) {
        lock.withLock {
            transform(&policy)
            if !isSupported {
                policy = .disabled
            }
        }
    }
}

enum GameInputProtectionAuthorizationStatus: String, Hashable, Sendable {
    case authorized
    case accessibilityRequired
    case inputMonitoringRequired
    case accessibilityAndInputMonitoringRequired

    func isAuthorized(for pane: GameInputProtectionPrivacyPane) -> Bool {
        !GameInputProtectionPrivacyPane.requiredPanes(for: self)
            .contains(pane)
    }
}

enum GameInputProtectionPrivacyPane: String, CaseIterable, Hashable, Sendable {
    case accessibility
    case inputMonitoring

    var settingsURL: URL? {
        switch self {
        case .accessibility:
            URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        case .inputMonitoring:
            URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            )
        }
    }

    static func requiredPanes(
        for status: GameInputProtectionAuthorizationStatus
    ) -> [Self] {
        switch status {
        case .authorized:
            []
        case .accessibilityRequired:
            [.accessibility]
        case .inputMonitoringRequired:
            [.inputMonitoring]
        case .accessibilityAndInputMonitoringRequired:
            [.accessibility, .inputMonitoring]
        }
    }
}

protocol GameInputProtectionAuthorizing: Sendable {
    func status() -> GameInputProtectionAuthorizationStatus
    @discardableResult func request() -> Bool
}

/// Public Apple listen-event authorization boundary. Launch code calls only
/// `status()`. A later explicit UI action may call `request()`.
struct GameInputProtectionAuthorization: GameInputProtectionAuthorizing {
    func status() -> GameInputProtectionAuthorizationStatus {
        let accessibilityTrusted = AXIsProcessTrustedWithOptions(nil)
        let inputMonitoringTrusted = CGPreflightListenEventAccess()
        return switch (accessibilityTrusted, inputMonitoringTrusted) {
        case (true, true): .authorized
        case (false, true): .accessibilityRequired
        case (true, false): .inputMonitoringRequired
        case (false, false): .accessibilityAndInputMonitoringRequired
        }
    }

    @discardableResult
    func request() -> Bool {
        let accessibilityTrusted = request(.accessibility)
        let inputMonitoringTrusted = request(.inputMonitoring)
        return accessibilityTrusted && inputMonitoringTrusted
    }

    @discardableResult
    func request(_ pane: GameInputProtectionPrivacyPane) -> Bool {
        switch pane {
        case .accessibility:
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:
                    true
            ] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            return CGRequestListenEventAccess()
        }
    }
}

enum GameInputProtectionError: LocalizedError, Equatable, Sendable {
    case accessibilityPermissionRequired
    case inputMonitoringPermissionRequired
    case accessibilityAndInputMonitoringPermissionsRequired
    case eventTapCreationFailed
    case eventTapEnableReadbackFailed
    case managedProcessGroupUnavailable(pid_t)
    case managedProcessBindingReadbackFailed(pid_t)

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            "게임 입력 보호를 사용하려면 손쉬운 사용 권한이 필요합니다. 시스템 설정에서 권한을 허용한 뒤 다시 실행해 주세요."
        case .inputMonitoringPermissionRequired:
            "게임 입력 보호를 사용하려면 입력 모니터링 권한이 필요합니다. 시스템 설정에서 권한을 허용한 뒤 다시 실행해 주세요."
        case .accessibilityAndInputMonitoringPermissionsRequired:
            "게임 입력 보호를 사용하려면 손쉬운 사용 및 입력 모니터링 권한이 필요합니다. 시스템 설정에서 권한을 허용한 뒤 다시 실행해 주세요."
        case .eventTapCreationFailed:
            "macOS에 저장된 권한 등록과 현재 ForgePlay.app이 일치하지 않거나 실제 입력 필터 승인이 갱신되지 않았습니다. 손쉬운 사용과 입력 모니터링에서 기존 ForgePlay 항목을 각각 제거한 뒤, Finder에서 보기로 현재 ForgePlay.app을 다시 추가해 두 권한을 켜고 ForgePlay를 완전히 종료했다가 다시 여세요."
        case .eventTapEnableReadbackFailed:
            "macOS에서 게임 입력 필터가 활성화된 것으로 확인되지 않았습니다. 손쉬운 사용 및 입력 모니터링 권한을 확인한 뒤 다시 실행해 주세요."
        case .managedProcessGroupUnavailable(let processIdentifier):
            "관리되는 게임 프로세스 \(processIdentifier)의 프로세스 그룹을 확인할 수 없습니다."
        case .managedProcessBindingReadbackFailed(let processIdentifier):
            "관리되는 게임 프로세스 \(processIdentifier)의 프로세스 그룹 연결이 확인 전에 변경되었습니다."
        }
    }
}

enum GameInputProtectionTerminalFailure: LocalizedError, Equatable, Sendable {
    case timeoutReenableReadbackFailed
    case repeatedTapTimeout
    case disabledByUserInput
    case pointerVisibilityRestoreFailed(CGError.RawValue)
    case modifierReleaseEmissionFailed(pid_t)

    var errorDescription: String? {
        switch self {
        case .timeoutReenableReadbackFailed:
            "macOS 게임 입력 필터가 시간 초과 후 다시 활성화되지 않았습니다. 보호되지 않은 실행을 중단합니다."
        case .repeatedTapTimeout:
            "macOS 게임 입력 필터가 반복해서 시간 초과되었습니다. 보호되지 않은 실행을 중단합니다."
        case .disabledByUserInput:
            "macOS가 사용자 입력으로 게임 입력 필터를 비활성화했습니다. 보호되지 않은 실행을 중단합니다."
        case .pointerVisibilityRestoreFailed:
            "macOS 포인터를 다시 표시하지 못했습니다. 포인터 상태를 복원하기 위해 보호된 실행을 중단합니다."
        case .modifierReleaseEmissionFailed:
            "변환된 보조키를 안전하게 해제하지 못했습니다. 키 상태를 복원하기 위해 보호된 실행을 중단합니다."
        }
    }
}

struct GameInputProtectionTerminalCleanupError:
    LocalizedError,
    Equatable,
    Sendable {
    let terminalFailure: GameInputProtectionTerminalFailure
    let cleanupCompleted: Bool
    let callerCancellationObserved: Bool
    let maskedCommitFailureTechnicalDescription: String?

    var errorDescription: String? { terminalFailure.errorDescription }
}

struct GameInputProtectionCommitFailureResolution: Equatable, Sendable {
    let terminalFailure: GameInputProtectionTerminalFailure
    let maskedCommitFailureTechnicalDescription: String?
}

struct GameInputProtectionPostDispatchCleanupError:
    LocalizedError,
    Equatable,
    Sendable {
    let originalFailureDescription: String
    let originalFailureTechnicalDescription: String
    let cleanupCompleted: Bool
    let callerCancellationObserved: Bool

    var errorDescription: String? { originalFailureDescription }
}

enum GameInputProtectionCommitFailureResolver {
    static func resolve(
        sessionTerminalFailure: GameInputProtectionTerminalFailure?,
        commitFailure: any Error,
        technicalDescription: (any Error) -> String
    ) -> GameInputProtectionCommitFailureResolution? {
        guard let terminalFailure = sessionTerminalFailure ??
                (commitFailure as? GameInputProtectionTerminalFailure) else {
            return nil
        }
        return GameInputProtectionCommitFailureResolution(
            terminalFailure: terminalFailure,
            maskedCommitFailureTechnicalDescription:
                commitFailure is GameInputProtectionTerminalFailure
                ? nil
                : technicalDescription(commitFailure)
        )
    }
}

typealias GameInputProtectionTerminalFailureHandler =
    @MainActor @Sendable (GameInputProtectionTerminalFailure) -> Void
typealias GameInputProtectionPointerHideFailureHandler =
    @MainActor @Sendable (CGError.RawValue) -> Void

struct GameInputProtectionSessionIdentity: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum GameInputProtectionLifecycleEvent: Equatable, Sendable {
    case protectionLost(
        session: GameInputProtectionSessionIdentity,
        failure: GameInputProtectionTerminalFailure
    )
    case containmentCompleted(
        session: GameInputProtectionSessionIdentity,
        failure: GameInputProtectionTerminalFailure
    )
}

typealias GameInputProtectionLifecycleEventHandler =
    @MainActor @Sendable (GameInputProtectionLifecycleEvent) -> Void

struct GameInputProtectionPointerHideFailureEvent: Equatable, Sendable {
    let session: GameInputProtectionSessionIdentity
    let resultCode: CGError.RawValue
}

@MainActor
protocol GameInputProtectionPointerHideFailurePublishing: AnyObject {
    func publish(_ event: GameInputProtectionPointerHideFailureEvent)
}

@MainActor
final class GameInputProtectionPointerHideFailureBroker:
    GameInputProtectionPointerHideFailurePublishing {
    typealias Handler = @MainActor @Sendable (
        GameInputProtectionPointerHideFailureEvent
    ) -> Void

    static let shared = GameInputProtectionPointerHideFailureBroker()

    private var handlers: [UUID: Handler] = [:]

    func subscribe(_ handler: @escaping Handler) -> UUID {
        let token = UUID()
        handlers[token] = handler
        return token
    }

    func unsubscribe(_ token: UUID) {
        handlers.removeValue(forKey: token)
    }

    func publish(_ event: GameInputProtectionPointerHideFailureEvent) {
        for handler in handlers.values { handler(event) }
    }
}

enum GameInputProtectionCommittedSessionGate {
    static func permitsBackgroundContainment(
        terminalSession: GameInputProtectionSessionIdentity,
        committedSession: GameInputProtectionSessionIdentity?,
        hasExistingContainment: Bool = false
    ) -> Bool {
        !hasExistingContainment && committedSession == terminalSession
    }
}

struct GameInputProtectionContainmentClaimToken: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct GameInputProtectionContainmentClaimRegistry: Sendable {
    enum Acquisition: Equatable, Sendable {
        case acquired(GameInputProtectionContainmentClaimToken)
        case existing(GameInputProtectionContainmentClaimToken)
    }

    private var claims: [String: GameInputProtectionContainmentClaimToken] = [:]

    mutating func acquire(prefixKey: String) -> Acquisition {
        if let existing = claims[prefixKey] { return .existing(existing) }
        let token = GameInputProtectionContainmentClaimToken()
        claims[prefixKey] = token
        return .acquired(token)
    }

    func hasClaim(prefixKey: String) -> Bool {
        claims[prefixKey] != nil
    }

    var isEmpty: Bool {
        claims.isEmpty
    }

    func isCurrent(
        prefixKey: String,
        token: GameInputProtectionContainmentClaimToken
    ) -> Bool {
        claims[prefixKey] == token
    }

    @discardableResult
    mutating func release(
        prefixKey: String,
        token: GameInputProtectionContainmentClaimToken
    ) -> Bool {
        guard claims[prefixKey] == token else { return false }
        claims.removeValue(forKey: prefixKey)
        return true
    }
}

enum GameInputProtectionDispatchAdmissionSite:
    String,
    CaseIterable,
    Sendable {
    case initial
    case bootstrapRetry
    case fallbackRetry
}

@MainActor
final class GameInputProtectionPostDispatchRollbackOwnership {
    private(set) var localInputAndControllerRollbackCompleted = false
    private(set) var rendererRollbackCompleted: Bool

    init(requiresRendererRollback: Bool) {
        rendererRollbackCompleted = !requiresRendererRollback
    }

    var allRollbackCompleted: Bool {
        localInputAndControllerRollbackCompleted && rendererRollbackCompleted
    }

    func markLocalInputAndControllerRollbackCompleted() {
        localInputAndControllerRollbackCompleted = true
    }

    func markRendererRollbackCompleted() {
        rendererRollbackCompleted = true
    }
}

@MainActor
enum GameInputProtectionPostDispatchClaimReleaseGate {
    @discardableResult
    static func releaseIfRollbackCompleted(
        ownership: GameInputProtectionPostDispatchRollbackOwnership,
        registry: inout GameInputProtectionContainmentClaimRegistry,
        prefixKey: String,
        token: GameInputProtectionContainmentClaimToken
    ) -> Bool {
        guard ownership.allRollbackCompleted else { return false }
        return registry.release(prefixKey: prefixKey, token: token)
    }
}

@MainActor
final class GameInputProtectionSafetyFirstLifecycleGate {
    private var lossEventWasReleased = false
    private var lossEventTask: Task<Void, Never>?

    /// Called from the already-created containment task immediately before its
    /// first shutdown attempt. The notification is separately queued, so its
    /// diagnostics can never delay task creation or the safety action.
    @discardableResult
    func admitShutdownAttemptAndQueueLossEvent(
        _ deliver: (@MainActor @Sendable () -> Void)?
    ) -> Bool {
        guard !lossEventWasReleased else { return false }
        lossEventWasReleased = true
        if let deliver {
            lossEventTask = Task { @MainActor in deliver() }
        }
        return true
    }

    /// Completion delivery remains non-blocking for containment, but cannot
    /// overtake the previously queued protection-loss notification.
    @discardableResult
    func queueCompletionAfterLossEvent(
        _ deliver: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never> {
        let lossEventTask = lossEventTask
        return Task { @MainActor in
            if let lossEventTask { await lossEventTask.value }
            deliver()
        }
    }
}

enum GameInputProtectionReceiptScope: String, Hashable, Sendable {
    case inactiveNoMutation
    /// This deliberately makes no claim about a later Wine/game child
    /// receiving or consuming a remapped key.
    case hostEventFilterArmedChildConsumptionNotObserved
    /// CoreGraphics reports whether the hide request was accepted, but offers
    /// no public cursor-visibility readback contract.
    case pointerLifecycleArmedVisibilityNotObserved
    /// Both independent host controls are armed; neither scope claims that a
    /// later Wine/game child consumed an input or that the cursor is invisible.
    case hostEventFilterAndPointerLifecycleArmedNoConsumptionOrVisibilityReadback
}

struct GameInputProtectionApplicationReceipt: Hashable, Sendable {
    let policy: GameInputProtectionPolicy
    let filterArmed: Bool
    let eventTapEnabledReadback: Bool
    let pointerHideRequested: Bool
    let pointerHideAttempted: Bool
    let pointerHideRequestSucceeded: Bool
    let pointerHideRequestResultCode: CGError.RawValue?
    let pointerVisibilityReadbackAvailable: Bool
    let pointerHideOwned: Bool
    let targetProcessIdentifier: pid_t?
    let targetProcessGroupIdentifier: pid_t?
    let scope: GameInputProtectionReceiptScope
    let timeoutReenableAttempted: Bool
    let restored: Bool

    var isLifecycleAdmissionVerified: Bool {
        if policy.requiresManagedTarget {
            guard targetProcessIdentifier != nil,
                  targetProcessGroupIdentifier != nil,
                  !restored else {
                return false
            }
            let eventTapSatisfied = policy.requiresEventTap
                ? filterArmed && eventTapEnabledReadback
                : !filterArmed && !eventTapEnabledReadback
            let pointerAttemptIsTruthful: Bool
            if pointerHideAttempted {
                pointerAttemptIsTruthful =
                    pointerHideRequestResultCode != nil &&
                    pointerHideRequestSucceeded ==
                        (pointerHideRequestResultCode == CGError.success.rawValue)
            } else {
                pointerAttemptIsTruthful =
                    pointerHideRequestResultCode == nil &&
                    !pointerHideRequestSucceeded &&
                    !pointerHideOwned
            }
            let pointerLifecycleSatisfied =
                policy.hidePointerWhileManagedGameFrontmost
                ? pointerHideRequested &&
                    pointerAttemptIsTruthful &&
                    !pointerVisibilityReadbackAvailable
                : !pointerHideRequested &&
                    !pointerHideAttempted &&
                    !pointerHideRequestSucceeded &&
                    pointerHideRequestResultCode == nil &&
                    !pointerHideOwned
            let expectedScope: GameInputProtectionReceiptScope
            switch (
                policy.requiresEventTap,
                policy.hidePointerWhileManagedGameFrontmost
            ) {
            case (true, true):
                expectedScope =
                    .hostEventFilterAndPointerLifecycleArmedNoConsumptionOrVisibilityReadback
            case (true, false):
                expectedScope =
                    .hostEventFilterArmedChildConsumptionNotObserved
            case (false, true):
                expectedScope = .pointerLifecycleArmedVisibilityNotObserved
            case (false, false):
                expectedScope = .inactiveNoMutation
            }
            return eventTapSatisfied &&
                pointerLifecycleSatisfied &&
                scope == expectedScope
        }
        return !filterArmed &&
            !eventTapEnabledReadback &&
            !pointerHideRequested &&
            !pointerHideAttempted &&
            !pointerHideRequestSucceeded &&
            pointerHideRequestResultCode == nil &&
            !pointerVisibilityReadbackAvailable &&
            !pointerHideOwned &&
            targetProcessIdentifier == nil &&
            targetProcessGroupIdentifier == nil &&
            scope == .inactiveNoMutation &&
            !timeoutReenableAttempted &&
            !restored
    }

}

enum GameInputProtectionRestorationPlan: Hashable, Sendable {
    case noRetention
    case inputOnly
    case leaseBacked
    case invalidMissingMutationLease

    static func resolve(
        inputRequiresRetention: Bool,
        prefixMutationRequiresRetention: Bool,
        hasRestorationLease: Bool
    ) -> Self {
        if prefixMutationRequiresRetention && !hasRestorationLease {
            return .invalidMissingMutationLease
        }
        if hasRestorationLease &&
            (inputRequiresRetention || prefixMutationRequiresRetention) {
            return .leaseBacked
        }
        if inputRequiresRetention {
            return .inputOnly
        }
        return .noRetention
    }
}

enum GameInputProtectionRestorationRetryPolicy {
    static func delaySeconds(afterConsecutiveFailure failureCount: Int) -> Int {
        guard failureCount > 0 else { return 0 }
        let exponent = min(failureCount - 1, 6)
        return min(60, 1 << exponent)
    }
}

@MainActor
enum GameInputProtectionPrecommitRestorationHandoff {
    /// `restore` may synchronously publish a terminal callback. Retention and
    /// monitor installation therefore follow immediately in the same actor
    /// turn whenever restoration reports remaining ownership.
    @discardableResult
    static func restoreOrInstallRetryOwner(
        restore: () -> Bool,
        retain: () -> Void,
        startMonitor: () -> Void
    ) -> Bool {
        guard !restore() else { return true }
        retain()
        startMonitor()
        return false
    }
}

enum GameInputProtectionRestorationMonitorOwnerGate {
    static func permitsRemoval(currentToken: UUID?, ownerToken: UUID) -> Bool {
        currentToken == ownerToken
    }
}

enum GameInputProtectionRestorationInactivityWaiter {
    typealias Probe = @Sendable (
        _ prefix: URL,
        _ timeout: TimeInterval,
        _ pollInterval: TimeInterval
    ) async throws -> Bool

    static func waitUntilInactive(
        _ prefix: URL,
        using probe: Probe
    ) async throws -> Bool {
        while !Task.isCancelled {
            if try await probe(prefix, 30, 0.2) {
                return true
            }
        }
        return false
    }
}

@MainActor
enum GameInputProtectionRestorationMonitorLoop {
    enum AttemptResult: Equatable, Sendable {
        case success
        case retry(String)
        case stop
    }

    enum FailureKind: Equatable, Sendable {
        case observation
        case restoration
    }

    static func run(
        observeInactivity: @escaping @MainActor @Sendable () async ->
            AttemptResult,
        restore: @escaping @MainActor @Sendable () async -> AttemptResult,
        failureRecorded: @escaping @MainActor @Sendable (
            _ kind: FailureKind,
            _ consecutiveFailures: Int,
            _ detail: String
        ) -> Void,
        sleep: @escaping @MainActor @Sendable (Int) async throws -> Void = {
            seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) async -> Bool {
        var observationFailures = 0
        var restorationFailures = 0
        while !Task.isCancelled {
            switch await observeInactivity() {
            case .success:
                observationFailures = 0
            case .retry(let detail):
                guard !Task.isCancelled else { return false }
                observationFailures += 1
                failureRecorded(
                    .observation,
                    observationFailures,
                    detail
                )
                do {
                    try await sleep(
                        GameInputProtectionRestorationRetryPolicy.delaySeconds(
                            afterConsecutiveFailure: observationFailures
                        )
                    )
                } catch {
                    return false
                }
                continue
            case .stop:
                return false
            }

            guard !Task.isCancelled else { return false }
            switch await restore() {
            case .success:
                return true
            case .retry(let detail):
                guard !Task.isCancelled else { return false }
                restorationFailures += 1
                failureRecorded(
                    .restoration,
                    restorationFailures,
                    detail
                )
                do {
                    try await sleep(
                        GameInputProtectionRestorationRetryPolicy.delaySeconds(
                            afterConsecutiveFailure: restorationFailures
                        )
                    )
                } catch {
                    return false
                }
            case .stop:
                return false
            }
        }
        return false
    }
}

struct GameInputProtectionTerminalContainmentState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case shutdown
        case restoration
        case complete
    }

    private(set) var phase = Phase.shutdown
    private(set) var consecutiveFailures = 0

    mutating func recordSuccess() {
        consecutiveFailures = 0
        switch phase {
        case .shutdown:
            phase = .restoration
        case .restoration:
            phase = .complete
        case .complete:
            break
        }
    }

    mutating func recordFailure() -> Int {
        guard phase != .complete else { return 0 }
        consecutiveFailures += 1
        return GameInputProtectionRestorationRetryPolicy.delaySeconds(
            afterConsecutiveFailure: consecutiveFailures
        )
    }
}

@MainActor
enum GameInputProtectionTerminalContainmentCoordinator {
    enum AttemptResult: Equatable, Sendable {
        case success
        case failure(String)
        case cancelled
    }

    static func run(
        attempt: @escaping @MainActor @Sendable
            (GameInputProtectionTerminalContainmentState.Phase) async ->
                AttemptResult,
        failureRecorded: @escaping @MainActor @Sendable
            (GameInputProtectionTerminalContainmentState, String) -> Void,
        sleep: @escaping @MainActor @Sendable (Int) async throws -> Void = {
            seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) async -> Bool {
        var state = GameInputProtectionTerminalContainmentState()
        while !Task.isCancelled, state.phase != .complete {
            switch await attempt(state.phase) {
            case .success:
                state.recordSuccess()
            case .failure(let detail):
                let delay = state.recordFailure()
                failureRecorded(state, detail)
                do {
                    try await sleep(delay)
                } catch {
                    return false
                }
            case .cancelled:
                return false
            }
        }
        return state.phase == .complete
    }
}

@MainActor
enum GameInputProtectionContainmentAdmissionWaiter {
    static func wait(
        whileActive isActive: @escaping @MainActor @Sendable () -> Bool,
        sleep: @escaping @MainActor @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(100))
        }
    ) async throws {
        try Task.checkCancellation()
        while isActive() {
            try Task.checkCancellation()
            try await sleep()
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
    }
}

@MainActor
enum GameInputProtectionContainmentClaimCompletionWaiter {
    static func wait(
        whileCurrent isCurrent: @escaping @MainActor @Sendable () -> Bool,
        sleep: @escaping @MainActor @Sendable () async -> Void = {
            try? await Task.sleep(for: .milliseconds(100))
        }
    ) async {
        while isCurrent() {
            await sleep()
        }
    }
}

@MainActor
enum GameInputProtectionForegroundClaimAcquirer {
    static func acquireFreshClaim(
        acquire: @escaping @MainActor @Sendable () ->
            GameInputProtectionContainmentClaimRegistry.Acquisition,
        waitForCompletion: @escaping @MainActor @Sendable
            (GameInputProtectionContainmentClaimToken) async -> Void
    ) async -> GameInputProtectionContainmentClaimToken {
        while true {
            switch acquire() {
            case .acquired(let token):
                return token
            case .existing(let token):
                _ = await GameInputProtectionCancellationShield.run {
                    await waitForCompletion(token)
                    return true
                }
            }
        }
    }
}

@MainActor
enum GameInputProtectionCancellationShield {
    struct Result: Equatable, Sendable {
        let cleanupCompleted: Bool
        let callerCancellationObserved: Bool
    }

    static func run(
        cleanup: @escaping @MainActor @Sendable () async -> Bool
    ) async -> Result {
        let cancellationObservedBeforeCleanup = Task.isCancelled
        let cleanupTask = Task.detached {
            await cleanup()
        }
        let cleanupCompleted = await cleanupTask.value
        return Result(
            cleanupCompleted: cleanupCompleted,
            callerCancellationObserved:
                cancellationObservedBeforeCleanup || Task.isCancelled
        )
    }
}

enum GameInputProtectionTerminalFailurePriority {
    static func error(
        terminalFailure: GameInputProtectionTerminalFailure,
        cleanupCompleted: Bool,
        callerCancellationObserved: Bool,
        maskedCommitFailureTechnicalDescription: String?
    ) -> any Error {
        if callerCancellationObserved ||
            !cleanupCompleted ||
            maskedCommitFailureTechnicalDescription != nil {
            return GameInputProtectionTerminalCleanupError(
                terminalFailure: terminalFailure,
                cleanupCompleted: cleanupCompleted,
                callerCancellationObserved: callerCancellationObserved,
                maskedCommitFailureTechnicalDescription:
                    maskedCommitFailureTechnicalDescription
            )
        }
        return terminalFailure
    }
}

enum GameInputProtectionPostDispatchFailurePriority {
    static func error(
        originalCommitFailure: any Error,
        originalFailureTechnicalDescription: String,
        terminalResolution: GameInputProtectionCommitFailureResolution?,
        cleanupCompleted: Bool,
        callerCancellationObserved: Bool
    ) -> any Error {
        if let terminalResolution {
            return GameInputProtectionTerminalFailurePriority.error(
                terminalFailure: terminalResolution.terminalFailure,
                cleanupCompleted: cleanupCompleted,
                callerCancellationObserved: callerCancellationObserved,
                maskedCommitFailureTechnicalDescription:
                    terminalResolution
                        .maskedCommitFailureTechnicalDescription
            )
        }
        if cleanupCompleted && !callerCancellationObserved {
            return originalCommitFailure
        }
        return GameInputProtectionPostDispatchCleanupError(
            originalFailureDescription:
                originalCommitFailure.localizedDescription,
            originalFailureTechnicalDescription:
                originalFailureTechnicalDescription,
            cleanupCompleted: cleanupCompleted,
            callerCancellationObserved: callerCancellationObserved
        )
    }
}

@MainActor
enum GameInputProtectionForegroundContainmentCleanup {
    static func run(
        attempt: @escaping @MainActor @Sendable
            (GameInputProtectionTerminalContainmentState.Phase) async ->
                GameInputProtectionTerminalContainmentCoordinator.AttemptResult,
        failureRecorded: @escaping @MainActor @Sendable
            (GameInputProtectionTerminalContainmentState, String) -> Void,
        cleanupFinished: @escaping @MainActor @Sendable (Bool) -> Void = {
            _ in
        },
        sleep: @escaping @MainActor @Sendable (Int) async throws -> Void = {
            seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) async -> GameInputProtectionCancellationShield.Result {
        let result = await GameInputProtectionCancellationShield.run {
            await GameInputProtectionTerminalContainmentCoordinator.run(
                attempt: attempt,
                failureRecorded: failureRecorded,
                sleep: sleep
            )
        }
        cleanupFinished(result.cleanupCompleted)
        return result
    }
}

@MainActor
enum GameInputProtectionForegroundTerminalContainment {
    static func run(
        terminalFailure: GameInputProtectionTerminalFailure,
        maskedCommitFailureTechnicalDescription: String? = nil,
        attempt: @escaping @MainActor @Sendable
            (GameInputProtectionTerminalContainmentState.Phase) async ->
                GameInputProtectionTerminalContainmentCoordinator.AttemptResult,
        failureRecorded: @escaping @MainActor @Sendable
            (GameInputProtectionTerminalContainmentState, String) -> Void,
        cleanupFinished: @escaping @MainActor @Sendable (Bool) -> Void = {
            _ in
        },
        sleep: @escaping @MainActor @Sendable (Int) async throws -> Void = {
            seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) async throws -> Never {
        let result = await GameInputProtectionForegroundContainmentCleanup.run(
            attempt: attempt,
            failureRecorded: failureRecorded,
            cleanupFinished: cleanupFinished,
            sleep: sleep
        )
        throw GameInputProtectionTerminalFailurePriority.error(
            terminalFailure: terminalFailure,
            cleanupCompleted: result.cleanupCompleted,
            callerCancellationObserved:
                result.callerCancellationObserved,
            maskedCommitFailureTechnicalDescription:
                maskedCommitFailureTechnicalDescription
        )
    }
}

struct GameInputProtectionEventFlags: OptionSet, Hashable, Sendable {
    let rawValue: UInt64

    static let shift = Self(rawValue: CGEventFlags.maskShift.rawValue)
    static let control = Self(rawValue: CGEventFlags.maskControl.rawValue)
    static let option = Self(rawValue: CGEventFlags.maskAlternate.rawValue)
    static let command = Self(rawValue: CGEventFlags.maskCommand.rawValue)

    fileprivate static let shortcutModifiers: Self = [
        .shift, .control, .option, .command
    ]
    fileprivate static let remappedModifiers: Self = [
        .control, .option, .command
    ]
}

enum GameInputProtectionEventKind: Hashable, Sendable {
    case keyDown
    case keyUp
    case flagsChanged
}

struct GameInputProtectionEvent: Hashable, Sendable {
    var kind: GameInputProtectionEventKind
    var keyCode: UInt16
    var flags: GameInputProtectionEventFlags
    var sourceUserData: Int64 = 0
}

enum GameInputProtectionSyntheticEventTag {
    // A ForgePlay-owned marker used only to keep release events emitted by
    // this filter from re-entering the same filter. It is not a delivery or
    // child-consumption receipt.
    static let sourceUserData = Int64(bitPattern: 0x4650_4D4F_4455_505F)
}

enum GameInputProtectionEventDisposition: Hashable, Sendable {
    case pass(GameInputProtectionEvent)
    case suppress
}

enum GameInputProtectionTapSignal: Hashable, Sendable {
    case event(GameInputProtectionEvent)
    case disabledByTimeout
    case disabledByUserInput
}

enum GameInputProtectionKeyCode {
    static let h = UInt16(kVK_ANSI_H)
    static let q = UInt16(kVK_ANSI_Q)
    static let w = UInt16(kVK_ANSI_W)
    static let digit3 = UInt16(kVK_ANSI_3)
    static let digit4 = UInt16(kVK_ANSI_4)
    static let digit6 = UInt16(kVK_ANSI_6)
    static let digit5 = UInt16(kVK_ANSI_5)
    static let tab = UInt16(kVK_Tab)
    static let space = UInt16(kVK_Space)
    static let escape = UInt16(kVK_Escape)
    static let m = UInt16(kVK_ANSI_M)
    static let leftArrow = UInt16(kVK_LeftArrow)
    static let rightArrow = UInt16(kVK_RightArrow)
    static let downArrow = UInt16(kVK_DownArrow)
    static let upArrow = UInt16(kVK_UpArrow)
    static let missionControlF3 = UInt16(kVK_F3)
    static let showDesktopF11 = UInt16(kVK_F11)

    static let leftCommand = UInt16(kVK_Command)
    static let rightCommand = UInt16(kVK_RightCommand)
    static let leftOption = UInt16(kVK_Option)
    static let rightOption = UInt16(kVK_RightOption)
    static let leftControl = UInt16(kVK_Control)
    static let rightControl = UInt16(kVK_RightControl)
}

struct GameInputProtectionEventProcessor {
    private enum PhysicalModifier {
        case command
        case option
        case control
    }

    private enum ModifierSide {
        case left
        case right
    }

    static func process(
        _ event: GameInputProtectionEvent,
        policy: GameInputProtectionPolicy
    ) -> GameInputProtectionEventDisposition {
        guard policy.isActive else { return .pass(event) }
        if isSafetyBypass(event) {
            return .pass(event)
        }
        if shouldSuppress(event, policy: policy) {
            return .suppress
        }
        guard let modifierMap = policy.modifierMap else {
            return .pass(event)
        }

        var mapped = event
        mapped.flags = remapFlags(event.flags, modifierMap: modifierMap)
        if let (source, side) = physicalModifier(for: event.keyCode) {
            let binding = binding(of: source, modifierMap: modifierMap)
            if binding == .disabled {
                return .suppress
            }
            guard let mappedKeyCode = keyCode(for: binding, side: side) else {
                return .suppress
            }
            mapped.keyCode = mappedKeyCode
        }
        if shouldSuppress(mapped, policy: policy) {
            return .suppress
        }
        return .pass(mapped)
    }

    fileprivate static func shouldSuppress(
        _ event: GameInputProtectionEvent,
        policy: GameInputProtectionPolicy
    ) -> Bool {
        let modifiers = event.flags.intersection(.shortcutModifiers)
        if policy.blockAppWindowManagementShortcuts,
           [GameInputProtectionKeyCode.q,
            GameInputProtectionKeyCode.w,
            GameInputProtectionKeyCode.h,
            GameInputProtectionKeyCode.m].contains(event.keyCode),
           modifiers == [.command] {
            return true
        }
        if policy.blockAppSwitchingShortcuts {
            if event.keyCode == GameInputProtectionKeyCode.tab,
               modifiers == [.command] ||
                modifiers == [.command, .shift] {
                return true
            }
            if event.keyCode == GameInputProtectionKeyCode.space,
               modifiers == [.command] {
                return true
            }
        }
        if policy.blockMissionControlSpaceShortcuts {
            if [GameInputProtectionKeyCode.upArrow,
                GameInputProtectionKeyCode.downArrow,
                GameInputProtectionKeyCode.leftArrow,
                GameInputProtectionKeyCode.rightArrow].contains(event.keyCode),
               modifiers == [.control] {
                return true
            }
            if [GameInputProtectionKeyCode.missionControlF3,
                GameInputProtectionKeyCode.showDesktopF11].contains(event.keyCode),
               modifiers.isEmpty {
                return true
            }
        }
        if policy.blockDefaultScreenshotShortcuts,
           [GameInputProtectionKeyCode.digit3,
            GameInputProtectionKeyCode.digit4,
            GameInputProtectionKeyCode.digit5,
            GameInputProtectionKeyCode.digit6].contains(event.keyCode),
           modifiers == [.command, .shift] ||
            modifiers == [.command, .shift, .control] {
            return true
        }
        return false
    }

    fileprivate static func isSafetyBypass(
        _ event: GameInputProtectionEvent
    ) -> Bool {
        let modifiers = event.flags.intersection(.shortcutModifiers)
        if event.keyCode == GameInputProtectionKeyCode.escape,
           modifiers == [.command, .option] {
            return true
        }
        if event.keyCode == GameInputProtectionKeyCode.q,
           modifiers == [.command, .control] {
            return true
        }
        // Power/media/system-defined events are outside the tap mask and are
        // therefore never delivered to this filter.
        return false
    }

    private static func remapFlags(
        _ flags: GameInputProtectionEventFlags,
        modifierMap: GameInputModifierMap
    ) -> GameInputProtectionEventFlags {
        var result = flags.subtracting(.remappedModifiers)
        if flags.contains(.command) {
            insertFlag(for: modifierMap.command, into: &result)
        }
        if flags.contains(.option) {
            insertFlag(for: modifierMap.option, into: &result)
        }
        if flags.contains(.control) {
            insertFlag(for: modifierMap.control, into: &result)
        }
        return result
    }

    private static func binding(
        of source: PhysicalModifier,
        modifierMap: GameInputModifierMap
    ) -> GameInputModifierBinding {
        switch source {
        case .command: modifierMap.command
        case .option: modifierMap.option
        case .control: modifierMap.control
        }
    }

    private static func insertFlag(
        for binding: GameInputModifierBinding,
        into flags: inout GameInputProtectionEventFlags
    ) {
        switch binding {
        case .control: flags.insert(.control)
        case .alt: flags.insert(.option)
        case .disabled: break
        }
    }

    private static func physicalModifier(
        for keyCode: UInt16
    ) -> (PhysicalModifier, ModifierSide)? {
        switch keyCode {
        case GameInputProtectionKeyCode.leftCommand: (.command, .left)
        case GameInputProtectionKeyCode.rightCommand: (.command, .right)
        case GameInputProtectionKeyCode.leftOption: (.option, .left)
        case GameInputProtectionKeyCode.rightOption: (.option, .right)
        case GameInputProtectionKeyCode.leftControl: (.control, .left)
        case GameInputProtectionKeyCode.rightControl: (.control, .right)
        default: nil
        }
    }

    private static func keyCode(
        for binding: GameInputModifierBinding,
        side: ModifierSide
    ) -> UInt16? {
        switch (binding, side) {
        case (.alt, .left): GameInputProtectionKeyCode.leftOption
        case (.alt, .right): GameInputProtectionKeyCode.rightOption
        case (.control, .left): GameInputProtectionKeyCode.leftControl
        case (.control, .right): GameInputProtectionKeyCode.rightControl
        case (.disabled, _): nil
        }
    }
}

private enum GameInputPhysicalModifierSource: CaseIterable, Hashable {
    case leftCommand
    case rightCommand
    case leftOption
    case rightOption
    case leftControl
    case rightControl

    init?(keyCode: UInt16) {
        switch keyCode {
        case GameInputProtectionKeyCode.leftCommand: self = .leftCommand
        case GameInputProtectionKeyCode.rightCommand: self = .rightCommand
        case GameInputProtectionKeyCode.leftOption: self = .leftOption
        case GameInputProtectionKeyCode.rightOption: self = .rightOption
        case GameInputProtectionKeyCode.leftControl: self = .leftControl
        case GameInputProtectionKeyCode.rightControl: self = .rightControl
        default: return nil
        }
    }

    var sourceFlag: GameInputProtectionEventFlags {
        switch self {
        case .leftCommand, .rightCommand: .command
        case .leftOption, .rightOption: .option
        case .leftControl, .rightControl: .control
        }
    }

    func binding(in modifierMap: GameInputModifierMap) ->
        GameInputModifierBinding {
        switch self {
        case .leftCommand, .rightCommand: modifierMap.command
        case .leftOption, .rightOption: modifierMap.option
        case .leftControl, .rightControl: modifierMap.control
        }
    }

    var isRightSide: Bool {
        switch self {
        case .rightCommand, .rightOption, .rightControl: true
        case .leftCommand, .leftOption, .leftControl: false
        }
    }
}

private enum GameInputModifierDestination: CaseIterable, Hashable {
    case leftControl
    case rightControl
    case leftAlt
    case rightAlt

    init?(
        binding: GameInputModifierBinding,
        source: GameInputPhysicalModifierSource
    ) {
        switch (binding, source.isRightSide) {
        case (.control, false): self = .leftControl
        case (.control, true): self = .rightControl
        case (.alt, false): self = .leftAlt
        case (.alt, true): self = .rightAlt
        case (.disabled, _): return nil
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .leftControl: GameInputProtectionKeyCode.leftControl
        case .rightControl: GameInputProtectionKeyCode.rightControl
        case .leftAlt: GameInputProtectionKeyCode.leftOption
        case .rightAlt: GameInputProtectionKeyCode.rightOption
        }
    }

    var flag: GameInputProtectionEventFlags {
        switch self {
        case .leftControl, .rightControl: .control
        case .leftAlt, .rightAlt: .option
        }
    }
}

private struct GameInputManagedProcessTargetIdentity: Hashable {
    let processIdentifier: pid_t
    let processGroupIdentifier: pid_t
}

private struct GameInputModifierDestinationOwnership: Hashable {
    let destination: GameInputModifierDestination
    let target: GameInputManagedProcessTargetIdentity
}

/// Stateful ownership is required because aggregate CGEvent flags cannot tell
/// which side released when both physical keys of one modifier are held. A
/// physical source owns one projected destination at the exact process target
/// that received its down edge until its matching release.
private struct GameInputModifierOwnershipLedger {
    private var ownershipBySource:
        [GameInputPhysicalModifierSource:
            GameInputModifierDestinationOwnership] = [:]
    private var ownersByOwnership:
        [GameInputModifierDestinationOwnership:
            Set<GameInputPhysicalModifierSource>] = [:]

    var hasOwnedDestinations: Bool { !ownershipBySource.isEmpty }

    mutating func process(
        _ event: GameInputProtectionEvent,
        policy: GameInputProtectionPolicy,
        target: GameInputManagedProcessTargetIdentity
    ) -> GameInputProtectionEventDisposition {
        guard policy.isActive else { return .pass(event) }
        guard event.sourceUserData !=
                GameInputProtectionSyntheticEventTag.sourceUserData else {
            return .pass(event)
        }
        if GameInputProtectionEventProcessor.isSafetyBypass(event) {
            return .pass(event)
        }
        if GameInputProtectionEventProcessor.shouldSuppress(
            event,
            policy: policy
        ) {
            return .suppress
        }
        guard let modifierMap = policy.modifierMap else {
            return .pass(event)
        }

        if let source = GameInputPhysicalModifierSource(keyCode: event.keyCode) {
            return processModifier(
                event,
                source: source,
                modifierMap: modifierMap,
                policy: policy,
                target: target
            )
        }

        var projected = event
        projected.flags = projectedFlags(
            preserving: event.flags,
            for: target
        )
        if GameInputProtectionEventProcessor.shouldSuppress(
            projected,
            policy: policy
        ) {
            return .suppress
        }
        return .pass(projected)
    }

    var pendingReleaseOwnerships: [GameInputModifierDestinationOwnership] {
        GameInputModifierDestination.allCases.flatMap { destination in
            ownersByOwnership.keys
                .filter {
                    $0.destination == destination &&
                        !(ownersByOwnership[$0] ?? []).isEmpty
                }
                .sorted {
                    if $0.target.processIdentifier !=
                        $1.target.processIdentifier {
                        return $0.target.processIdentifier <
                            $1.target.processIdentifier
                    }
                    return $0.target.processGroupIdentifier <
                        $1.target.processGroupIdentifier
                }
        }
    }

    func releaseEvent(
        for ownership: GameInputModifierDestinationOwnership
    ) -> GameInputProtectionEvent {
        let remainingFlags = ownersByOwnership.reduce(
            into: GameInputProtectionEventFlags()
        ) { flags, entry in
            guard entry.key != ownership,
                  entry.key.target == ownership.target,
                  !entry.value.isEmpty else {
                return
            }
            flags.insert(entry.key.destination.flag)
        }
        return GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: ownership.destination.keyCode,
            flags: remainingFlags,
            sourceUserData: GameInputProtectionSyntheticEventTag.sourceUserData
        )
    }

    mutating func commitRelease(
        of ownership: GameInputModifierDestinationOwnership
    ) {
        let sources = ownersByOwnership.removeValue(forKey: ownership) ?? []
        for source in sources {
            ownershipBySource.removeValue(forKey: source)
        }
    }

    mutating func clear(target: GameInputManagedProcessTargetIdentity) {
        let ownerships = ownersByOwnership.keys.filter { $0.target == target }
        for ownership in ownerships {
            commitRelease(of: ownership)
        }
    }

    mutating func clear() {
        ownershipBySource.removeAll(keepingCapacity: false)
        ownersByOwnership.removeAll(keepingCapacity: false)
    }

    private mutating func processModifier(
        _ event: GameInputProtectionEvent,
        source: GameInputPhysicalModifierSource,
        modifierMap: GameInputModifierMap,
        policy: GameInputProtectionPolicy,
        target: GameInputManagedProcessTargetIdentity
    ) -> GameInputProtectionEventDisposition {
        let binding = source.binding(in: modifierMap)
        guard binding != .disabled else {
            // Disabled sources never cross the managed host filter, on either
            // edge, and therefore never become release owners.
            return .suppress
        }
        guard let destination = GameInputModifierDestination(
            binding: binding,
            source: source
        ) else {
            return .suppress
        }

        let isDown: Bool
        switch event.kind {
        case .keyDown:
            isDown = true
        case .keyUp:
            isDown = false
        case .flagsChanged:
            // A tracked source's next flagsChanged edge is its release. This
            // remains correct when the aggregate source flag stays set because
            // the opposite-side physical key is still held.
            isDown = ownershipBySource[source] == nil &&
                event.flags.contains(source.sourceFlag)
        }

        if isDown {
            guard ownershipBySource[source] == nil else { return .suppress }
            let ownership = GameInputModifierDestinationOwnership(
                destination: destination,
                target: target
            )
            let wasUnowned = (ownersByOwnership[ownership] ?? []).isEmpty
            ownershipBySource[source] = ownership
            ownersByOwnership[ownership, default: []].insert(source)
            guard wasUnowned else { return .suppress }

            var projected = event
            projected.keyCode = destination.keyCode
            projected.flags = projectedFlags(
                preserving: event.flags,
                for: target
            )
            if GameInputProtectionEventProcessor.shouldSuppress(
                projected,
                policy: policy
            ) {
                return .suppress
            }
            return .pass(projected)
        }

        guard let ownership = ownershipBySource[source] else {
            // Do not leak an unmatched physical Windows-key-style release.
            return .suppress
        }
        // A physical up routed to a different same-group application cannot
        // safely stand in for the down recipient's release. The focus-change
        // path drains the original ownership directly to its exact PID.
        guard ownership.target == target else { return .suppress }
        ownershipBySource.removeValue(forKey: source)
        ownersByOwnership[ownership]?.remove(source)
        let hasRemainingOwners =
            !(ownersByOwnership[ownership] ?? []).isEmpty
        if !hasRemainingOwners {
            ownersByOwnership.removeValue(forKey: ownership)
        }
        guard !hasRemainingOwners else { return .suppress }

        var projected = event
        projected.keyCode = ownership.destination.keyCode
        projected.flags = projectedFlags(
            preserving: event.flags,
            for: target
        )
        return .pass(projected)
    }

    private func activeDestinationFlags(
        for target: GameInputManagedProcessTargetIdentity
    ) -> GameInputProtectionEventFlags {
        ownersByOwnership.reduce(into: []) { flags, entry in
            if entry.key.target == target, !entry.value.isEmpty {
                flags.insert(entry.key.destination.flag)
            }
        }
    }

    private func projectedFlags(
        preserving sourceFlags: GameInputProtectionEventFlags,
        for target: GameInputManagedProcessTargetIdentity
    ) -> GameInputProtectionEventFlags {
        var projected = sourceFlags.subtracting(.remappedModifiers)
        projected.formUnion(activeDestinationFlags(for: target))
        return projected
    }
}

enum GameInputModifierReleaseEmissionResult: Equatable, Sendable {
    /// CoreGraphics accepted a public post request. No child-consumption
    /// readback is available or claimed.
    case submittedNoConsumptionReadback
    case failed
}

@MainActor
protocol GameInputModifierReleaseEmitting: AnyObject {
    func emitRelease(
        _ event: GameInputProtectionEvent,
        to processIdentifier: pid_t
    ) -> GameInputModifierReleaseEmissionResult
}

@MainActor
final class CoreGraphicsGameInputModifierReleaseEmitter:
    GameInputModifierReleaseEmitting {
    func emitRelease(
        _ release: GameInputProtectionEvent,
        to processIdentifier: pid_t
    ) -> GameInputModifierReleaseEmissionResult {
        guard processIdentifier > 0,
              let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(release.keyCode),
                keyDown: false
              ) else {
            return .failed
        }
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: release.flags.rawValue)
        event.setIntegerValueField(
            .eventSourceUserData,
            value: GameInputProtectionSyntheticEventTag.sourceUserData
        )
        event.postToPid(processIdentifier)
        return .submittedNoConsumptionReadback
    }
}

private enum GameInputModifierReleaseRestorer {
    enum Result: Equatable {
        case restored
        case targetGoneOrRebound
        case emissionFailed(pid_t)
    }

    @MainActor
    static func restore(
        ledger: inout GameInputModifierOwnershipLedger,
        processTargetProvider: GameInputProtectionProcessTargetProviding,
        releaseEmitter: GameInputModifierReleaseEmitting
    ) -> Result {
        guard ledger.hasOwnedDestinations else { return .restored }
        var discardedReboundTarget = false
        for ownership in ledger.pendingReleaseOwnerships {
            let target = ownership.target
            // Revalidate the recorded PID/PGID pair immediately before every
            // post so target exit or a process-group rebound cannot redirect a
            // later release.
            guard target.processIdentifier > 0,
                  target.processGroupIdentifier > 0,
                  target.processGroupIdentifier != getpgrp(),
                  processTargetProvider.processGroupIdentifier(
                    for: target.processIdentifier
                  ) == target.processGroupIdentifier else {
                ledger.clear(target: target)
                discardedReboundTarget = true
                continue
            }
            let release = ledger.releaseEvent(for: ownership)
            guard releaseEmitter.emitRelease(
                release,
                to: target.processIdentifier
            ) == .submittedNoConsumptionReadback else {
                return .emissionFailed(target.processIdentifier)
            }
            ledger.commitRelease(of: ownership)
        }
        return discardedReboundTarget ? .targetGoneOrRebound : .restored
    }
}

@MainActor
protocol GameInputProtectionTap: AnyObject {
    var isEnabled: Bool { get }
    func enable()
    func invalidate()
}

@MainActor
protocol GameInputProtectionTapCreating: AnyObject {
    func makeTap(
        handler: @escaping (GameInputProtectionTapSignal) ->
            GameInputProtectionEventDisposition
    ) -> GameInputProtectionTap?
}

@MainActor
protocol GameInputPointerVisibilityDriving: AnyObject {
    func hidePointer() -> CGError
    func showPointer() -> CGError
}

@MainActor
protocol GameInputPointerRestorationCoordinating: AnyObject {
    func retainRestorationOwnership(
        for pointerVisibilityDriver: GameInputPointerVisibilityDriving
    )
}

@MainActor
final class CoreGraphicsGameInputPointerVisibilityDriver:
    GameInputPointerVisibilityDriving {
    func hidePointer() -> CGError {
        CGDisplayHideCursor(CGMainDisplayID())
    }

    func showPointer() -> CGError {
        CGDisplayShowCursor(CGMainDisplayID())
    }
}

@MainActor
final class GameInputPointerRestorationCoordinator:
    GameInputPointerRestorationCoordinating {
    typealias Sleep = @MainActor @Sendable (UInt64) async throws -> Void

    static let shared = GameInputPointerRestorationCoordinator()

    private struct PendingRestoration {
        let pointerVisibilityDriver: GameInputPointerVisibilityDriving
        var consecutiveFailures: Int
        var task: Task<Void, Never>?
    }

    private let sleep: Sleep
    private var pending: [UUID: PendingRestoration] = [:]
    private var terminationObserver: NSObjectProtocol?
    private var isTerminating = false
    private(set) var acceptedOwnershipCount = 0

    var pendingRestorationCount: Int { pending.count }

    init(
        sleep: @escaping Sleep = { seconds in
            try await Task.sleep(
                nanoseconds: seconds * 1_000_000_000
            )
        },
        observesApplicationTermination: Bool = true
    ) {
        self.sleep = sleep
        if observesApplicationTermination {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applicationWillTerminate()
                }
            }
        }
    }

    func retainRestorationOwnership(
        for pointerVisibilityDriver: GameInputPointerVisibilityDriving
    ) {
        acceptedOwnershipCount += 1
        let identifier = UUID()
        pending[identifier] = PendingRestoration(
            pointerVisibilityDriver: pointerVisibilityDriver,
            consecutiveFailures: 0,
            task: nil
        )
        if isTerminating {
            attemptRestorationDuringTermination(identifier: identifier)
            return
        }
        scheduleAttempt(identifier: identifier, after: 0)
    }

    func cancelRetriesForApplicationTermination() {
        applicationWillTerminate()
    }

    private func scheduleAttempt(identifier: UUID, after seconds: UInt64) {
        guard pending[identifier] != nil else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if seconds > 0 { try await sleep(seconds) }
                try Task.checkCancellation()
            } catch {
                return
            }
            attemptRestoration(identifier: identifier)
        }
        pending[identifier]?.task = task
    }

    private func attemptRestoration(identifier: UUID) {
        guard var restoration = pending[identifier] else { return }
        restoration.task = nil
        if restoration.pointerVisibilityDriver.showPointer() == .success {
            pending.removeValue(forKey: identifier)
            return
        }
        restoration.consecutiveFailures += 1
        pending[identifier] = restoration
        let delay = UInt64(
            GameInputProtectionRestorationRetryPolicy.delaySeconds(
                afterConsecutiveFailure: restoration.consecutiveFailures
            )
        )
        scheduleAttempt(identifier: identifier, after: delay)
    }

    private func applicationWillTerminate() {
        isTerminating = true
        for identifier in Array(pending.keys) {
            guard let restoration = pending[identifier] else { continue }
            restoration.task?.cancel()
            if restoration.pointerVisibilityDriver.showPointer() == .success {
                pending.removeValue(forKey: identifier)
            } else {
                pending[identifier]?.task = nil
            }
        }
    }

    private func attemptRestorationDuringTermination(identifier: UUID) {
        guard let restoration = pending[identifier] else { return }
        restoration.task?.cancel()
        if restoration.pointerVisibilityDriver.showPointer() == .success {
            pending.removeValue(forKey: identifier)
        } else {
            pending[identifier]?.task = nil
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let terminationObserver {
                NotificationCenter.default.removeObserver(terminationObserver)
            }
            pending.values.forEach { $0.task?.cancel() }
            for identifier in Array(pending.keys) {
                attemptRestorationDuringTermination(identifier: identifier)
            }
        }
    }
}

@MainActor
protocol GameInputProtectionProcessTargetProviding: AnyObject {
    func frontmostApplicationProcessIdentifier() -> pid_t?
    func processGroupIdentifier(for processIdentifier: pid_t) -> pid_t?
    func startFrontmostApplicationMonitoring(
        _ handler: @escaping @MainActor @Sendable (pid_t?) -> Void
    )
    func stopFrontmostApplicationMonitoring()
}

@MainActor
protocol GameInputModifierRestorationCoordinating: AnyObject {
    typealias Attempt = @MainActor () -> Bool

    func retainRestorationOwnership(attempt: @escaping Attempt)
}

@MainActor
final class GameInputModifierRestorationCoordinator:
    GameInputModifierRestorationCoordinating {
    typealias Sleep = @MainActor @Sendable (UInt64) async throws -> Void

    static let shared = GameInputModifierRestorationCoordinator()

    private struct PendingRestoration {
        let attempt: Attempt
        var consecutiveFailures: Int
        var task: Task<Void, Never>?
    }

    private let sleep: Sleep
    private var pending: [UUID: PendingRestoration] = [:]
    private var terminationObserver: NSObjectProtocol?
    private var isTerminating = false
    private(set) var acceptedOwnershipCount = 0

    var pendingRestorationCount: Int { pending.count }

    init(
        sleep: @escaping Sleep = { seconds in
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        },
        observesApplicationTermination: Bool = true
    ) {
        self.sleep = sleep
        if observesApplicationTermination {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applicationWillTerminate()
                }
            }
        }
    }

    func retainRestorationOwnership(attempt: @escaping Attempt) {
        acceptedOwnershipCount += 1
        let identifier = UUID()
        pending[identifier] = PendingRestoration(
            attempt: attempt,
            consecutiveFailures: 0,
            task: nil
        )
        if isTerminating {
            attemptRestorationDuringTermination(identifier: identifier)
        } else {
            scheduleAttempt(identifier: identifier, after: 0)
        }
    }

    func cancelRetriesForApplicationTermination() {
        applicationWillTerminate()
    }

    private func scheduleAttempt(identifier: UUID, after seconds: UInt64) {
        guard pending[identifier] != nil else { return }
        let task = Task { @MainActor [weak self] in
            do {
                if seconds > 0 {
                    guard let sleep = self?.sleep else { return }
                    try await sleep(seconds)
                }
                try Task.checkCancellation()
            } catch {
                return
            }
            self?.attemptRestoration(identifier: identifier)
        }
        pending[identifier]?.task = task
    }

    private func attemptRestoration(identifier: UUID) {
        guard var restoration = pending[identifier] else { return }
        restoration.task = nil
        if restoration.attempt() {
            pending.removeValue(forKey: identifier)
            return
        }
        restoration.consecutiveFailures += 1
        pending[identifier] = restoration
        let delay = UInt64(
            GameInputProtectionRestorationRetryPolicy.delaySeconds(
                afterConsecutiveFailure: restoration.consecutiveFailures
            )
        )
        scheduleAttempt(identifier: identifier, after: delay)
    }

    private func applicationWillTerminate() {
        isTerminating = true
        for identifier in Array(pending.keys) {
            attemptRestorationDuringTermination(identifier: identifier)
        }
    }

    private func attemptRestorationDuringTermination(identifier: UUID) {
        guard let restoration = pending[identifier] else { return }
        restoration.task?.cancel()
        if restoration.attempt() {
            pending.removeValue(forKey: identifier)
        } else {
            pending[identifier]?.task = nil
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let terminationObserver {
                NotificationCenter.default.removeObserver(terminationObserver)
            }
            pending.values.forEach { $0.task?.cancel() }
            for identifier in Array(pending.keys) {
                attemptRestorationDuringTermination(identifier: identifier)
            }
        }
    }
}

@MainActor
protocol GameInputProtectionDriving: AnyObject {
    var requiresLifecycleRetention: Bool { get }
    func prepare(policy: GameInputProtectionPolicy) throws
    func bindManagedProcess(processIdentifier: pid_t) throws
    func applicationReceipt() throws -> GameInputProtectionApplicationReceipt
    func setTerminalFailureHandler(
        _ handler: GameInputProtectionTerminalFailureHandler?
    )
    func setPointerHideFailureHandler(
        _ handler: GameInputProtectionPointerHideFailureHandler?
    )
    @discardableResult func restore() -> Bool
}

@MainActor
final class MacOSGameInputProtectionProcessTargetProvider:
    GameInputProtectionProcessTargetProviding {
    private var activationObserver: NSObjectProtocol?

    func frontmostApplicationProcessIdentifier() -> pid_t? {
        guard let processIdentifier = NSWorkspace.shared.frontmostApplication?
            .processIdentifier,
              processIdentifier > 0 else {
            return nil
        }
        return processIdentifier
    }

    func processGroupIdentifier(for processIdentifier: pid_t) -> pid_t? {
        guard processIdentifier > 0 else { return nil }
        let processGroup = getpgid(processIdentifier)
        return processGroup > 0 ? processGroup : nil
    }

    func startFrontmostApplicationMonitoring(
        _ handler: @escaping @MainActor @Sendable (pid_t?) -> Void
    ) {
        stopFrontmostApplicationMonitoring()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication
            MainActor.assumeIsolated {
                handler(application?.processIdentifier)
            }
        }
    }

    func stopFrontmostApplicationMonitoring() {
        guard let activationObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        self.activationObserver = nil
    }

    deinit {
        MainActor.assumeIsolated {
            stopFrontmostApplicationMonitoring()
        }
    }
}

@MainActor
final class GameInputProtectionController: GameInputProtectionDriving {
    private let authorization: GameInputProtectionAuthorizing
    private let tapFactory: GameInputProtectionTapCreating
    private let processTargetProvider: GameInputProtectionProcessTargetProviding
    private let pointerVisibilityDriver: GameInputPointerVisibilityDriving
    private let pointerRestorationCoordinator:
        GameInputPointerRestorationCoordinating
    private let modifierReleaseEmitter: GameInputModifierReleaseEmitting
    private let modifierRestorationCoordinator:
        GameInputModifierRestorationCoordinating
    private var policy = GameInputProtectionPolicy.disabled
    private var tap: GameInputProtectionTap?
    private var targetProcessIdentifier: pid_t?
    private var targetProcessGroupIdentifier: pid_t?
    private var lastManagedFrontmostTarget:
        GameInputManagedProcessTargetIdentity?
    private var frontmostApplicationIsInManagedProcessGroup = false
    private var modifierOwnershipLedger = GameInputModifierOwnershipLedger()
    private var pointerHideAttempted = false
    private var pointerHideRequestSucceeded = false
    private var pointerHideRequestResultCode: CGError.RawValue?
    private var pointerHideOwned = false
    private var suppressedKeyCodesLow: UInt64 = 0
    private var suppressedKeyCodesHigh: UInt64 = 0
    private var timeoutReenableAttempted = false
    private var prepared = false
    private var restored = false
    private var terminalFailure: GameInputProtectionTerminalFailure?
    private var terminalFailureHandler:
        GameInputProtectionTerminalFailureHandler?
    private var pointerHideFailureHandler:
        GameInputProtectionPointerHideFailureHandler?
    private var terminalFailureWasDelivered = false

    var requiresLifecycleRetention: Bool {
        policy.requiresManagedTarget &&
            prepared &&
            !restored &&
            terminalFailure == nil &&
            (tap != nil || policy.hidePointerWhileManagedGameFrontmost)
    }

    init(
        authorization: GameInputProtectionAuthorizing =
            GameInputProtectionAuthorization(),
        tapFactory: GameInputProtectionTapCreating? = nil,
        processTargetProvider: GameInputProtectionProcessTargetProviding? = nil,
        pointerVisibilityDriver: GameInputPointerVisibilityDriving? = nil,
        pointerRestorationCoordinator:
            GameInputPointerRestorationCoordinating? = nil,
        modifierReleaseEmitter: GameInputModifierReleaseEmitting? = nil,
        modifierRestorationCoordinator:
            GameInputModifierRestorationCoordinating? = nil
    ) {
        self.authorization = authorization
        self.tapFactory = tapFactory ??
            CoreGraphicsGameInputProtectionTapFactory()
        self.processTargetProvider = processTargetProvider ??
            MacOSGameInputProtectionProcessTargetProvider()
        self.pointerVisibilityDriver = pointerVisibilityDriver ??
            CoreGraphicsGameInputPointerVisibilityDriver()
        self.pointerRestorationCoordinator = pointerRestorationCoordinator ??
            GameInputPointerRestorationCoordinator.shared
        self.modifierReleaseEmitter = modifierReleaseEmitter ??
            CoreGraphicsGameInputModifierReleaseEmitter()
        self.modifierRestorationCoordinator = modifierRestorationCoordinator ??
            GameInputModifierRestorationCoordinator.shared
    }

    func prepare(policy: GameInputProtectionPolicy) throws {
        precondition(!prepared && !restored)
        self.policy = policy
        guard policy.requiresManagedTarget else {
            prepared = true
            return
        }
        guard policy.requiresEventTap else {
            prepared = true
            return
        }
        try requireAuthorization()
        guard let tap = tapFactory.makeTap(handler: { [weak self] signal in
            self?.handle(signal) ?? {
                if case .event(let event) = signal { return .pass(event) }
                return .suppress
            }()
        }) else {
            // TCC can change between preflight and event-tap creation. Report
            // the exact missing grant instead of collapsing that race into a
            // generic filter error.
            try requireAuthorization()
            throw GameInputProtectionError.eventTapCreationFailed
        }
        self.tap = tap
        guard tap.isEnabled else {
            tap.invalidate()
            self.tap = nil
            throw GameInputProtectionError.eventTapEnableReadbackFailed
        }
        prepared = true
    }

    private func requireAuthorization() throws {
        switch authorization.status() {
        case .authorized:
            return
        case .accessibilityRequired:
            throw GameInputProtectionError.accessibilityPermissionRequired
        case .inputMonitoringRequired:
            throw GameInputProtectionError.inputMonitoringPermissionRequired
        case .accessibilityAndInputMonitoringRequired:
            throw GameInputProtectionError
                .accessibilityAndInputMonitoringPermissionsRequired
        }
    }

    func bindManagedProcess(processIdentifier: pid_t) throws {
        guard policy.requiresManagedTarget else { return }
        guard let processGroup = processTargetProvider
            .processGroupIdentifier(for: processIdentifier) else {
            throw GameInputProtectionError
                .managedProcessGroupUnavailable(processIdentifier)
        }
        guard processGroup > 0, processGroup != getpgrp() else {
            throw GameInputProtectionError
                .managedProcessBindingReadbackFailed(processIdentifier)
        }
        targetProcessIdentifier = processIdentifier
        targetProcessGroupIdentifier = processGroup
        guard processTargetProvider.processGroupIdentifier(
            for: processIdentifier
        ) == processGroup else {
            targetProcessIdentifier = nil
            targetProcessGroupIdentifier = nil
            throw GameInputProtectionError
                .managedProcessBindingReadbackFailed(processIdentifier)
        }
        processTargetProvider.startFrontmostApplicationMonitoring {
            [weak self] frontmostProcessIdentifier in
            self?.refreshFrontmostApplicationMembership(
                processIdentifier: frontmostProcessIdentifier
            )
        }
        refreshFrontmostApplicationMembership(
            processIdentifier:
                processTargetProvider.frontmostApplicationProcessIdentifier()
        )
    }

    func applicationReceipt() throws -> GameInputProtectionApplicationReceipt {
        if let terminalFailure { throw terminalFailure }
        guard policy.requiresManagedTarget else {
            return GameInputProtectionApplicationReceipt(
                policy: policy,
                filterArmed: false,
                eventTapEnabledReadback: false,
                pointerHideRequested: false,
                pointerHideAttempted: false,
                pointerHideRequestSucceeded: false,
                pointerHideRequestResultCode: nil,
                pointerVisibilityReadbackAvailable: false,
                pointerHideOwned: false,
                targetProcessIdentifier: nil,
                targetProcessGroupIdentifier: nil,
                scope: .inactiveNoMutation,
                timeoutReenableAttempted: false,
                restored: false
            )
        }
        if policy.requiresEventTap {
            guard let tap, tap.isEnabled else {
                throw GameInputProtectionError.eventTapEnableReadbackFailed
            }
        }
        guard let targetProcessIdentifier,
              let targetProcessGroupIdentifier else {
            throw GameInputProtectionError.managedProcessGroupUnavailable(0)
        }
        guard targetProcessGroupIdentifier != getpgrp(),
              processTargetProvider.processGroupIdentifier(
                for: targetProcessIdentifier
              ) == targetProcessGroupIdentifier else {
            throw GameInputProtectionError.managedProcessBindingReadbackFailed(
                targetProcessIdentifier
            )
        }
        let scope: GameInputProtectionReceiptScope
        switch (
            policy.requiresEventTap,
            policy.hidePointerWhileManagedGameFrontmost
        ) {
        case (true, true):
            scope =
                .hostEventFilterAndPointerLifecycleArmedNoConsumptionOrVisibilityReadback
        case (true, false):
            scope = .hostEventFilterArmedChildConsumptionNotObserved
        case (false, true):
            scope = .pointerLifecycleArmedVisibilityNotObserved
        case (false, false):
            scope = .inactiveNoMutation
        }
        return GameInputProtectionApplicationReceipt(
            policy: policy,
            filterArmed: policy.requiresEventTap,
            eventTapEnabledReadback: policy.requiresEventTap,
            pointerHideRequested:
                policy.hidePointerWhileManagedGameFrontmost,
            pointerHideAttempted: pointerHideAttempted,
            pointerHideRequestSucceeded: pointerHideRequestSucceeded,
            pointerHideRequestResultCode: pointerHideRequestResultCode,
            pointerVisibilityReadbackAvailable: false,
            pointerHideOwned: pointerHideOwned,
            targetProcessIdentifier: targetProcessIdentifier,
            targetProcessGroupIdentifier: targetProcessGroupIdentifier,
            scope: scope,
            timeoutReenableAttempted: timeoutReenableAttempted,
            restored: false
        )
    }

    func setTerminalFailureHandler(
        _ handler: GameInputProtectionTerminalFailureHandler?
    ) {
        terminalFailureHandler = handler
        deliverTerminalFailureIfPossible()
    }

    func setPointerHideFailureHandler(
        _ handler: GameInputProtectionPointerHideFailureHandler?
    ) {
        pointerHideFailureHandler = handler
    }

    @discardableResult
    func restore() -> Bool {
        guard !restored else { return true }
        tap?.invalidate()
        tap = nil
        processTargetProvider.stopFrontmostApplicationMonitoring()
        let modifierFailure = drainOwnedModifierReleases()
        let pointerFailure = restoreOwnedPointerHide()
        if let failure = modifierFailure ?? pointerFailure {
            terminateProtectionWithoutPointerRetry(failure)
            return false
        }
        targetProcessIdentifier = nil
        targetProcessGroupIdentifier = nil
        lastManagedFrontmostTarget = nil
        frontmostApplicationIsInManagedProcessGroup = false
        suppressedKeyCodesLow = 0
        suppressedKeyCodesHigh = 0
        prepared = false
        restored = true
        terminalFailureHandler = nil
        pointerHideFailureHandler = nil
        return true
    }

    private func handle(
        _ signal: GameInputProtectionTapSignal
    ) -> GameInputProtectionEventDisposition {
        switch signal {
        case .disabledByTimeout:
            if !timeoutReenableAttempted, let tap {
                timeoutReenableAttempted = true
                tap.enable()
                if tap.isEnabled {
                    return .suppress
                }
                terminateProtection(.timeoutReenableReadbackFailed)
            } else {
                terminateProtection(.repeatedTapTimeout)
            }
            return .suppress
        case .disabledByUserInput:
            terminateProtection(.disabledByUserInput)
            return .suppress
        case .event(let event):
            guard terminalFailure == nil else { return .pass(event) }
            guard frontmostApplicationIsInManagedProcessGroup,
                  let lastManagedFrontmostTarget else {
                // Unbound, unproven, stale, or unrelated targets fail open.
                return .pass(event)
            }
            if event.kind == .keyUp,
               consumeSuppressedKeyCode(event.keyCode) {
                return .suppress
            }
            let disposition = modifierOwnershipLedger.process(
                event,
                policy: policy,
                target: lastManagedFrontmostTarget
            )
            if disposition == .suppress, event.kind == .keyDown {
                recordSuppressedKeyCode(event.keyCode)
            }
            return disposition
        }
    }

    private func terminateProtection(
        _ failure: GameInputProtectionTerminalFailure
    ) {
        guard terminalFailure == nil else { return }
        tap?.invalidate()
        tap = nil
        processTargetProvider.stopFrontmostApplicationMonitoring()
        let modifierReleaseFailure = drainOwnedModifierReleases()
        let pointerRestoreFailure = restoreOwnedPointerHide()
        terminalFailure = modifierReleaseFailure ?? pointerRestoreFailure ?? failure
        frontmostApplicationIsInManagedProcessGroup = false
        suppressedKeyCodesLow = 0
        suppressedKeyCodesHigh = 0
        deliverTerminalFailureIfPossible()
    }

    private func deliverTerminalFailureIfPossible() {
        guard !terminalFailureWasDelivered,
              let terminalFailure,
              let terminalFailureHandler else {
            return
        }
        terminalFailureWasDelivered = true
        terminalFailureHandler(terminalFailure)
    }

    private func refreshFrontmostApplicationMembership(
        processIdentifier: pid_t?
    ) {
        guard terminalFailure == nil else { return }
        guard let processIdentifier,
              let expectedGroup = targetProcessGroupIdentifier,
              processIdentifier > 0,
              expectedGroup > 0,
              expectedGroup != getpgrp(),
              processTargetProvider.processGroupIdentifier(
                for: processIdentifier
              ) == expectedGroup else {
            frontmostApplicationIsInManagedProcessGroup = false
            suppressedKeyCodesLow = 0
            suppressedKeyCodesHigh = 0
            let modifierFailure = drainOwnedModifierReleases()
            let pointerFailure = restoreOwnedPointerHide()
            if let failure = modifierFailure ?? pointerFailure {
                terminateProtectionWithoutPointerRetry(failure)
            }
            return
        }
        let target = GameInputManagedProcessTargetIdentity(
            processIdentifier: processIdentifier,
            processGroupIdentifier: expectedGroup
        )
        if frontmostApplicationIsInManagedProcessGroup,
           lastManagedFrontmostTarget != target {
            // A modifier down belongs to the exact managed application that
            // received it. Drain that target before another application in the
            // same Wine process group becomes the event destination.
            suppressedKeyCodesLow = 0
            suppressedKeyCodesHigh = 0
            if let modifierFailure = drainOwnedModifierReleases() {
                terminateProtectionWithoutPointerRetry(modifierFailure)
                return
            }
        }
        lastManagedFrontmostTarget = target
        guard !frontmostApplicationIsInManagedProcessGroup else { return }
        frontmostApplicationIsInManagedProcessGroup = true
        guard policy.hidePointerWhileManagedGameFrontmost else { return }
        pointerHideAttempted = true
        let result = pointerVisibilityDriver.hidePointer()
        pointerHideRequestResultCode = result.rawValue
        pointerHideRequestSucceeded = result == .success
        if result == .success {
            pointerHideOwned = true
        } else {
            pointerHideFailureHandler?(result.rawValue)
        }
    }

    private func restoreOwnedPointerHide() -> GameInputProtectionTerminalFailure? {
        guard pointerHideOwned else { return nil }
        let result = pointerVisibilityDriver.showPointer()
        guard result == .success else {
            return .pointerVisibilityRestoreFailed(result.rawValue)
        }
        pointerHideOwned = false
        return nil
    }

    private func drainOwnedModifierReleases() ->
        GameInputProtectionTerminalFailure? {
        switch GameInputModifierReleaseRestorer.restore(
            ledger: &modifierOwnershipLedger,
            processTargetProvider: processTargetProvider,
            releaseEmitter: modifierReleaseEmitter
        ) {
        case .restored, .targetGoneOrRebound:
            return nil
        case .emissionFailed(let processIdentifier):
            return .modifierReleaseEmissionFailed(processIdentifier)
        }
    }

    private func terminateProtectionWithoutPointerRetry(
        _ failure: GameInputProtectionTerminalFailure
    ) {
        guard terminalFailure == nil else { return }
        terminalFailure = failure
        tap?.invalidate()
        tap = nil
        processTargetProvider.stopFrontmostApplicationMonitoring()
        frontmostApplicationIsInManagedProcessGroup = false
        suppressedKeyCodesLow = 0
        suppressedKeyCodesHigh = 0
        deliverTerminalFailureIfPossible()
    }

    private func recordSuppressedKeyCode(_ keyCode: UInt16) {
        guard keyCode < 128 else { return }
        if keyCode < 64 {
            suppressedKeyCodesLow |= UInt64(1) << UInt64(keyCode)
        } else {
            suppressedKeyCodesHigh |= UInt64(1) << UInt64(keyCode - 64)
        }
    }

    private func consumeSuppressedKeyCode(_ keyCode: UInt16) -> Bool {
        guard keyCode < 128 else { return false }
        if keyCode < 64 {
            let mask = UInt64(1) << UInt64(keyCode)
            guard suppressedKeyCodesLow & mask != 0 else { return false }
            suppressedKeyCodesLow &= ~mask
            return true
        }
        let mask = UInt64(1) << UInt64(keyCode - 64)
        guard suppressedKeyCodesHigh & mask != 0 else { return false }
        suppressedKeyCodesHigh &= ~mask
        return true
    }

    deinit {
        MainActor.assumeIsolated {
            tap?.invalidate()
            processTargetProvider.stopFrontmostApplicationMonitoring()
            if drainOwnedModifierReleases() != nil,
               modifierOwnershipLedger.hasOwnedDestinations {
                var transferredLedger = modifierOwnershipLedger
                modifierOwnershipLedger.clear()
                let processTargetProvider = processTargetProvider
                let modifierReleaseEmitter = modifierReleaseEmitter
                modifierRestorationCoordinator.retainRestorationOwnership {
                    switch GameInputModifierReleaseRestorer.restore(
                        ledger: &transferredLedger,
                        processTargetProvider: processTargetProvider,
                        releaseEmitter: modifierReleaseEmitter
                    ) {
                    case .restored, .targetGoneOrRebound:
                        return true
                    case .emissionFailed:
                        return false
                    }
                }
            }
            if pointerHideOwned {
                pointerRestorationCoordinator.retainRestorationOwnership(
                    for: pointerVisibilityDriver
                )
                pointerHideOwned = false
            }
        }
    }

}

@MainActor
final class CoreGraphicsGameInputProtectionTapFactory:
    GameInputProtectionTapCreating {
    func makeTap(
        handler: @escaping (GameInputProtectionTapSignal) ->
            GameInputProtectionEventDisposition
    ) -> GameInputProtectionTap? {
        CoreGraphicsGameInputProtectionTap(handler: handler)
    }
}

private func gameInputProtectionEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<CoreGraphicsGameInputProtectionTap>
        .fromOpaque(userInfo).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}

@MainActor
private final class CoreGraphicsGameInputProtectionTap:
    GameInputProtectionTap {
    private let handler: (GameInputProtectionTapSignal) ->
        GameInputProtectionEventDisposition
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isEnabled: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    init?(
        handler: @escaping (GameInputProtectionTapSignal) ->
            GameInputProtectionEventDisposition
    ) {
        self.handler = handler
        let mask = [
            CGEventType.keyDown,
            CGEventType.keyUp,
            CGEventType.flagsChanged
        ].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: gameInputProtectionEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            return nil
        }
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            runLoopSource,
            .commonModes
        )
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func enable() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func invalidate() {
        if let runLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                runLoopSource,
                .commonModes
            )
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
    }

    deinit {
        MainActor.assumeIsolated {
            invalidate()
        }
    }

    nonisolated func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        MainActor.assumeIsolated {
            switch type {
            case .tapDisabledByTimeout:
                _ = handler(.disabledByTimeout)
                return Unmanaged.passUnretained(event)
            case .tapDisabledByUserInput:
                _ = handler(.disabledByUserInput)
                return Unmanaged.passUnretained(event)
            case .keyDown, .keyUp, .flagsChanged:
                let kind: GameInputProtectionEventKind = switch type {
                case .keyDown: .keyDown
                case .keyUp: .keyUp
                default: .flagsChanged
                }
                let projected = GameInputProtectionEvent(
                    kind: kind,
                    keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(
                        .keyboardEventKeycode
                    )),
                    flags: GameInputProtectionEventFlags(
                        rawValue: event.flags.rawValue
                    ),
                    sourceUserData: event.getIntegerValueField(
                        .eventSourceUserData
                    )
                )
                switch handler(.event(projected)) {
                case .suppress:
                    return nil
                case .pass(let mapped):
                    event.setIntegerValueField(
                        .keyboardEventKeycode,
                        value: Int64(mapped.keyCode)
                    )
                    event.flags = CGEventFlags(rawValue: mapped.flags.rawValue)
                    return Unmanaged.passUnretained(event)
                }
            default:
                return Unmanaged.passUnretained(event)
            }
        }
    }
}
