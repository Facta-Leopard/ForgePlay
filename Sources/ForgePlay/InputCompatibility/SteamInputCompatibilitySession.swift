import CoreGraphics
import Darwin
import Foundation

typealias SteamInputCompatibilityTerminalFailureHandler =
    @MainActor @Sendable (
        GameInputProtectionSessionIdentity,
        GameInputProtectionTerminalFailure
    ) -> Void

enum SteamInputCompatibilitySessionError: LocalizedError, Equatable, Sendable {
    case globalCursorCaptureUnsupported
    case modifierMappingInvalid(String)
    case modifierBridgeUnavailable
    case modifierBridgeReadbackFailed
    case cursorRestoreFailed(String)
    case sessionAlreadyActive

    var errorDescription: String? {
        switch self {
        case .globalCursorCaptureUnsupported:
            "FPS 상대 포인터 캡처(베타)는 게임 창에 한정할 수 있는 공개 경계가 없어 현재 비활성화되어 있습니다."
        case .modifierMappingInvalid(let reason):
            "키보드 보조키 매핑이 모호하거나 올바르지 않습니다: \(reason)"
        case .modifierBridgeUnavailable:
            "관리되는 Wine 입력의 실제 보조키 적용·관찰 ABI가 없어 요청한 매핑을 적용할 수 없습니다."
        case .modifierBridgeReadbackFailed:
            "키보드 보조키 적용 상태를 실제 Wine 입력 경계에서 다시 읽지 못했습니다."
        case .cursorRestoreFailed(let operation):
            "입력 호환성 세션을 안전하게 복원하지 못했습니다: \(operation)"
        case .sessionAlreadyActive:
            "다른 입력 호환성 세션이 아직 활성 상태입니다."
        }
    }
}

enum KeyboardModifierApplicationDisposition: String, Hashable, Sendable {
    /// The host and Wine input stacks are intentionally left untouched.
    case systemDefaultNoMutation
}

struct FPSRelativeCursorApplicationReceipt: Hashable, Sendable {
    let requested: Bool
    let captured: Bool
    let displayIdentifier: UInt32?
    let confinementBounds: CGRect?
    let readbackLocation: CGPoint?
    let restored: Bool

    var isAppliedAndReadBack: Bool {
        !requested &&
            !captured &&
            displayIdentifier == nil &&
            confinementBounds == nil &&
            readbackLocation == nil &&
            !restored
    }
}

struct KeyboardModifierBridgeApplicationReceipt: Hashable, Sendable {
    let requestedPreset: KeyboardMappingPreset
    let requestedPermutation: ModifierKeyPermutation?
    let disposition: KeyboardModifierApplicationDisposition
    let bridgeEnabled: Bool
    let targetProcessIdentifier: pid_t?
    let readbackPermutation: ModifierKeyPermutation?
    let restored: Bool

    var isAppliedAndReadBack: Bool {
        requestedPreset == .systemDefault &&
            requestedPermutation == nil &&
            disposition == .systemDefaultNoMutation &&
            !bridgeEnabled &&
            targetProcessIdentifier == nil &&
            readbackPermutation == nil &&
            !restored
    }
}

struct SteamInputCompatibilityApplicationReceipt: Hashable, Sendable {
    let cursor: FPSRelativeCursorApplicationReceipt
    let keyboard: KeyboardModifierBridgeApplicationReceipt
    let gameInputProtection: GameInputProtectionApplicationReceipt

    var isLifecycleAdmissionVerified: Bool {
        cursor.isAppliedAndReadBack &&
            keyboard.isAppliedAndReadBack &&
            gameInputProtection.isLifecycleAdmissionVerified
    }

    /// Compatibility spelling retained for callers that cannot yet be
    /// mechanically republished. New code uses `isLifecycleAdmissionVerified`.
    var isAppliedAndReadBack: Bool { isLifecycleAdmissionVerified }

    var isResourceFreeNoMutation: Bool {
        isLifecycleAdmissionVerified &&
            keyboard.disposition == .systemDefaultNoMutation &&
            !gameInputProtection.policy.isActive
    }
}

@MainActor
final class SteamInputCompatibilitySession {
    let identity: GameInputProtectionSessionIdentity
    private let keyboardMapping: KeyboardMappingPreference
    private let gameInputProtectionPolicy: GameInputProtectionPolicy
    private let gameInputProtection: GameInputProtectionDriving
    private let terminalFailureHandler:
        SteamInputCompatibilityTerminalFailureHandler?
    private let pointerHideFailurePublisher:
        GameInputProtectionPointerHideFailurePublishing
    private var isPrepared = false
    private var didPublishPointerHideFailure = false
    private(set) var isRestored = false
    private(set) var terminalFailure: GameInputProtectionTerminalFailure?

    var requiresLifecycleRetention: Bool {
        gameInputProtection.requiresLifecycleRetention
    }

    var requiresFailClosedManagedTransportBinding: Bool {
        gameInputProtectionPolicy.requiresEventTap
    }

    var permitsDetachedHandoffDegradation: Bool {
        !gameInputProtectionPolicy.requiresEventTap
    }

    var isResourceFreeProtectionPolicy: Bool {
        !gameInputProtectionPolicy.requiresManagedTarget
    }

    init(
        cursorPolicy: FPSCursorCapturePolicy,
        keyboardMapping: KeyboardMappingPreference,
        gameInputProtectionPolicy: GameInputProtectionPolicy = .disabled,
        gameInputProtection: GameInputProtectionDriving? = nil,
        terminalFailureHandler:
            SteamInputCompatibilityTerminalFailureHandler? = nil,
        pointerHideFailurePublisher:
            GameInputProtectionPointerHideFailurePublishing =
                GameInputProtectionPointerHideFailureBroker.shared
    ) throws {
        try Self.requireSupported(
            cursorPolicy: cursorPolicy,
            keyboardMapping: keyboardMapping
        )
        identity = GameInputProtectionSessionIdentity()
        self.keyboardMapping = keyboardMapping
        self.gameInputProtectionPolicy = gameInputProtectionPolicy
        self.gameInputProtection = gameInputProtection ??
            GameInputProtectionController()
        self.terminalFailureHandler = terminalFailureHandler
        self.pointerHideFailurePublisher = pointerHideFailurePublisher
        self.gameInputProtection.setTerminalFailureHandler { [weak self] in
            self?.receiveTerminalFailure($0)
        }
        self.gameInputProtection.setPointerHideFailureHandler { [weak self] in
            self?.receivePointerHideFailure(resultCode: $0)
        }
    }

    static func requireSupported(
        cursorPolicy: FPSCursorCapturePolicy,
        keyboardMapping: KeyboardMappingPreference
    ) throws {
        guard cursorPolicy == .off else {
            throw SteamInputCompatibilitySessionError
                .globalCursorCaptureUnsupported
        }
        guard keyboardMapping.preset == .systemDefault,
              keyboardMapping.customPermutation == nil else {
            throw SteamInputCompatibilitySessionError.modifierBridgeUnavailable
        }
    }

    func captureBeforeLaunch() throws {
        try requireNoTerminalFailure()
        guard !isPrepared, !isRestored else {
            throw SteamInputCompatibilitySessionError.sessionAlreadyActive
        }
        try gameInputProtection.prepare(policy: gameInputProtectionPolicy)
        isPrepared = true
    }

    func bindManagedWineTransport(processIdentifier: pid_t) throws {
        try requireNoTerminalFailure()
        guard isPrepared, !isRestored, processIdentifier > 0 else {
            throw SteamInputCompatibilitySessionError.modifierBridgeReadbackFailed
        }
        try gameInputProtection.bindManagedProcess(
            processIdentifier: processIdentifier
        )
    }

    func applicationReceipt() throws -> SteamInputCompatibilityApplicationReceipt {
        try requireNoTerminalFailure()
        guard isPrepared, !isRestored else {
            throw SteamInputCompatibilitySessionError.modifierBridgeReadbackFailed
        }
        let gameInputProtectionReceipt =
            try gameInputProtection.applicationReceipt()
        let receipt = SteamInputCompatibilityApplicationReceipt(
            cursor: FPSRelativeCursorApplicationReceipt(
                requested: false,
                captured: false,
                displayIdentifier: nil,
                confinementBounds: nil,
                readbackLocation: nil,
                restored: false
            ),
            keyboard: KeyboardModifierBridgeApplicationReceipt(
                requestedPreset: keyboardMapping.preset,
                requestedPermutation: nil,
                disposition: .systemDefaultNoMutation,
                bridgeEnabled: false,
                targetProcessIdentifier: nil,
                readbackPermutation: nil,
                restored: false
            ),
            gameInputProtection: gameInputProtectionReceipt
        )
        guard receipt.isLifecycleAdmissionVerified else {
            throw SteamInputCompatibilitySessionError.modifierBridgeReadbackFailed
        }
        return receipt
    }

    func requireNoTerminalFailure() throws {
        if let terminalFailure { throw terminalFailure }
    }

    @discardableResult
    func restore() -> Bool {
        guard !isRestored else { return true }
        guard gameInputProtection.restore() else { return false }
        isPrepared = false
        isRestored = true
        return true
    }

    private func receiveTerminalFailure(
        _ failure: GameInputProtectionTerminalFailure
    ) {
        guard terminalFailure == nil else { return }
        terminalFailure = failure
        terminalFailureHandler?(identity, failure)
    }

    private func receivePointerHideFailure(resultCode: CGError.RawValue) {
        guard !didPublishPointerHideFailure else { return }
        didPublishPointerHideFailure = true
        pointerHideFailurePublisher.publish(
            GameInputProtectionPointerHideFailureEvent(
                session: identity,
                resultCode: resultCode
            )
        )
    }

    deinit {
        MainActor.assumeIsolated {
            _ = restore()
        }
    }
}
