import Foundation
import Observation

enum NavigationStableSessionOwnershipError: LocalizedError, Equatable {
    case transitionInProgress
    case sessionAlreadyActive
    case noActiveSession
    case preparationNotInProgress
    case standardSteamLaunchReserved
    case standardSteamLaunchReservationMismatch
    case standardSteamLaunchNotReady
    case windowsExecutableLaunchReserved
    case windowsExecutableLaunchBlockedByCompatibilitySession
    case windowsExecutableLaunchBlockedByCompatibilityTransition
    case windowsExecutableLaunchNotReady

    var errorDescription: String? {
        switch self {
        case .transitionInProgress:
            "호환성 Steam 세션 작업이 이미 진행 중입니다."
        case .sessionAlreadyActive:
            "기존 호환성 Steam 세션을 먼저 종료하고 기준 상태 복원을 확인하세요."
        case .noActiveSession:
            "종료할 활성 호환성 Steam 세션이 없습니다."
        case .preparationNotInProgress:
            "호환성 Steam 세션 준비 상태가 올바르지 않습니다."
        case .standardSteamLaunchReserved:
            "일반 Steam 실행 전환이 진행 중입니다."
        case .standardSteamLaunchReservationMismatch:
            "일반 Steam 실행 전환 중 호환성 세션 상태가 변경되었습니다."
        case .standardSteamLaunchNotReady:
            "호환성 세션 복원 또는 다른 프리픽스 작업이 끝나지 않았습니다."
        case .windowsExecutableLaunchReserved:
            "다른 Windows EXE 실행 전환이 진행 중입니다."
        case .windowsExecutableLaunchBlockedByCompatibilitySession:
            "활성 호환성 Steam 세션을 먼저 종료하세요."
        case .windowsExecutableLaunchBlockedByCompatibilityTransition:
            "호환성 Steam 세션 전환이 끝날 때까지 기다리세요."
        case .windowsExecutableLaunchNotReady:
            "Steam 실행 또는 다른 프리픽스 작업이 끝날 때까지 기다리세요."
        }
    }
}

struct WindowsExecutableLaunchReservation: Equatable {
    let id: UUID
}

enum WindowsExecutableLaunchReservationAvailability: Equatable {
    case available
    case blockedByCompatibilitySession
    case blockedByCompatibilityTransition
    case blockedByStandardSteamLaunch
    case blockedByWindowsExecutableLaunch
    case blockedByPrefixLifecycle

    var error: NavigationStableSessionOwnershipError? {
        switch self {
        case .available:
            nil
        case .blockedByCompatibilitySession:
            .windowsExecutableLaunchBlockedByCompatibilitySession
        case .blockedByCompatibilityTransition:
            .windowsExecutableLaunchBlockedByCompatibilityTransition
        case .blockedByStandardSteamLaunch, .blockedByPrefixLifecycle:
            .windowsExecutableLaunchNotReady
        case .blockedByWindowsExecutableLaunch:
            .windowsExecutableLaunchReserved
        }
    }
}

struct WindowsExecutableLaunchReservationGate {
    private(set) var activeReservation: WindowsExecutableLaunchReservation?

    var isReserved: Bool {
        activeReservation != nil
    }

    func availability(
        hasActiveCompatibilitySession: Bool,
        compatibilityTransitionInProgress: Bool,
        standardSteamLaunchIsReserved: Bool,
        prefixLifecycleIsBusy: Bool
    ) -> WindowsExecutableLaunchReservationAvailability {
        if compatibilityTransitionInProgress {
            return .blockedByCompatibilityTransition
        }
        if standardSteamLaunchIsReserved {
            return .blockedByStandardSteamLaunch
        }
        if hasActiveCompatibilitySession {
            return .blockedByCompatibilitySession
        }
        if activeReservation != nil {
            return .blockedByWindowsExecutableLaunch
        }
        if prefixLifecycleIsBusy {
            return .blockedByPrefixLifecycle
        }
        return .available
    }

    mutating func reserve(
        hasActiveCompatibilitySession: Bool,
        compatibilityTransitionInProgress: Bool,
        standardSteamLaunchIsReserved: Bool,
        prefixLifecycleIsBusy: Bool
    ) throws -> WindowsExecutableLaunchReservation {
        let availability = availability(
            hasActiveCompatibilitySession: hasActiveCompatibilitySession,
            compatibilityTransitionInProgress: compatibilityTransitionInProgress,
            standardSteamLaunchIsReserved: standardSteamLaunchIsReserved,
            prefixLifecycleIsBusy: prefixLifecycleIsBusy
        )
        if let error = availability.error {
            throw error
        }
        let reservation = WindowsExecutableLaunchReservation(id: UUID())
        activeReservation = reservation
        return reservation
    }

    func requireCompatibilityOrStandardMutationAllowed() throws {
        guard activeReservation == nil else {
            throw NavigationStableSessionOwnershipError
                .windowsExecutableLaunchReserved
        }
    }

    mutating func release(_ reservation: WindowsExecutableLaunchReservation) {
        guard activeReservation == reservation else { return }
        activeReservation = nil
    }
}

struct StandardSteamCompatibilitySessionIdentity: Equatable {
    let receiptID: String
    let requestDigest: String
}

struct StandardSteamLaunchReservation: Equatable {
    let id: UUID
    let expectedCompatibilitySessionIdentity: StandardSteamCompatibilitySessionIdentity?

    var requiresCompatibilityReconciliation: Bool {
        expectedCompatibilitySessionIdentity != nil
    }
}

struct StandardSteamLaunchReservationGate {
    private(set) var activeReservation: StandardSteamLaunchReservation?

    var isReserved: Bool {
        activeReservation != nil
    }

    mutating func reserve(
        hasActiveCompatibilitySession: Bool,
        activeCompatibilitySessionIdentity: StandardSteamCompatibilitySessionIdentity?,
        compatibilityTransitionInProgress: Bool,
        prefixLifecycleIsBusy: Bool
    ) throws -> StandardSteamLaunchReservation {
        guard activeReservation == nil,
              !compatibilityTransitionInProgress else {
            throw NavigationStableSessionOwnershipError.standardSteamLaunchReserved
        }
        if hasActiveCompatibilitySession {
            guard let activeCompatibilitySessionIdentity else {
                throw NavigationStableSessionOwnershipError
                    .standardSteamLaunchReservationMismatch
            }
            let reservation = StandardSteamLaunchReservation(
                id: UUID(),
                expectedCompatibilitySessionIdentity: activeCompatibilitySessionIdentity
            )
            activeReservation = reservation
            return reservation
        }
        guard !prefixLifecycleIsBusy else {
            throw NavigationStableSessionOwnershipError.standardSteamLaunchNotReady
        }
        let reservation = StandardSteamLaunchReservation(
            id: UUID(),
            expectedCompatibilitySessionIdentity: nil
        )
        activeReservation = reservation
        return reservation
    }

    func requireCompatibilityMutationAllowed() throws {
        guard activeReservation == nil else {
            throw NavigationStableSessionOwnershipError.standardSteamLaunchReserved
        }
    }

    func validateExpectedCompatibilitySession(
        for reservation: StandardSteamLaunchReservation,
        currentIdentity: StandardSteamCompatibilitySessionIdentity?
    ) throws {
        guard activeReservation == reservation,
              reservation.expectedCompatibilitySessionIdentity == currentIdentity else {
            throw NavigationStableSessionOwnershipError
                .standardSteamLaunchReservationMismatch
        }
    }

    func validateReadyForStandardLaunch(
        _ reservation: StandardSteamLaunchReservation,
        hasActiveCompatibilitySession: Bool,
        compatibilityTransitionInProgress: Bool,
        prefixLifecycleIsBusy: Bool
    ) throws {
        guard activeReservation == reservation else {
            throw NavigationStableSessionOwnershipError
                .standardSteamLaunchReservationMismatch
        }
        guard !hasActiveCompatibilitySession,
              !compatibilityTransitionInProgress,
              !prefixLifecycleIsBusy else {
            throw NavigationStableSessionOwnershipError.standardSteamLaunchNotReady
        }
    }

    mutating func release(_ reservation: StandardSteamLaunchReservation) {
        guard activeReservation == reservation else { return }
        activeReservation = nil
    }
}

enum StandardSteamCompatibilitySessionHandoff: Equatable {
    case ready
    case reconcileActiveSession
    case blockedByCompatibilityTransition
    case blockedByAnotherPrefixOperation

    static func resolve(
        hasActiveCompatibilitySession: Bool,
        compatibilityTransitionInProgress: Bool,
        prefixLifecycleIsBusy: Bool
    ) -> Self {
        if compatibilityTransitionInProgress {
            return .blockedByCompatibilityTransition
        }
        if hasActiveCompatibilitySession {
            return .reconcileActiveSession
        }
        if prefixLifecycleIsBusy {
            return .blockedByAnotherPrefixOperation
        }
        return .ready
    }
}

/// Owns a session independently from any one SwiftUI view instance.
///
/// `Provider` is intentionally retained until completion succeeds. This keeps
/// provider-owned resources, including a security-scoped authorization lease,
/// alive while the user navigates away from and back to the launch screen.
@MainActor
@Observable
final class NavigationStableSessionOwner<Session, Provider, Presentation> {
    private(set) var lastSession: Session?
    private(set) var activePresentation: Presentation?
    private(set) var isTransitionInProgress = false
    @ObservationIgnored private var activeProvider: Provider?

    var hasActiveSession: Bool {
        activeProvider != nil
    }

    func beginPreparation() throws {
        guard !isTransitionInProgress else {
            throw NavigationStableSessionOwnershipError.transitionInProgress
        }
        guard activeProvider == nil else {
            throw NavigationStableSessionOwnershipError.sessionAlreadyActive
        }
        isTransitionInProgress = true
    }

    func commitPreparedSession(
        _ session: Session,
        provider: Provider,
        presentation: Presentation
    ) throws {
        guard isTransitionInProgress else {
            throw NavigationStableSessionOwnershipError.preparationNotInProgress
        }
        activeProvider = provider
        lastSession = session
        activePresentation = presentation
        isTransitionInProgress = false
    }

    func failPreparation() {
        isTransitionInProgress = false
    }

    @discardableResult
    func updateActivePresentation(_ presentation: Presentation) -> Bool {
        guard activeProvider != nil else { return false }
        activePresentation = presentation
        return true
    }

    func completeActiveSession(
        validating completedSessionValidator:
            @MainActor (Session, Session) throws -> Void = { _, _ in },
        using operation: @MainActor (Provider, Session) async throws -> Session
    ) async throws -> Session {
        guard !isTransitionInProgress else {
            throw NavigationStableSessionOwnershipError.transitionInProgress
        }
        guard let provider = activeProvider,
              let session = lastSession else {
            throw NavigationStableSessionOwnershipError.noActiveSession
        }

        isTransitionInProgress = true
        do {
            let completedSession = try await operation(provider, session)
            try completedSessionValidator(session, completedSession)
            lastSession = completedSession
            activeProvider = nil
            activePresentation = nil
            isTransitionInProgress = false
            return completedSession
        } catch {
            // Retain both the provider and its original receipt so restoration
            // can be retried after a transient completion failure.
            isTransitionInProgress = false
            throw error
        }
    }

    func clearCompletedSession() {
        guard !isTransitionInProgress,
              activeProvider == nil else { return }
        lastSession = nil
        activePresentation = nil
    }
}

struct SteamCompatibilitySessionPresentationState {
    let recipeIdentity: SteamCompatibilityProfileIdentity
    let selections: CompatibilitySteamLaunchUserSelectionsV1
    let fieldProvenance: [
        CompatibilitySteamLaunchOptionKindV1: CompatibilityResolvedValueProvenanceV1
    ]
    var savedPreference: CompatibilitySteamLaunchPreferenceEnvelopeV1?

    var selectedRecipeID: String {
        recipeIdentity.deterministicRecordID
    }
}

@MainActor
@Observable
final class SteamCompatibilitySessionCoordinator {
    @ObservationIgnored private let owner = NavigationStableSessionOwner<
        CompatibilitySteamLaunchPreparationV1,
        any CompatibilityLaunchRuntimeProviderV1,
        SteamCompatibilitySessionPresentationState
    >()
    private var standardSteamLaunchReservationGate =
        StandardSteamLaunchReservationGate()
    private var windowsExecutableLaunchReservationGate =
        WindowsExecutableLaunchReservationGate()

    var lastPreparation: CompatibilitySteamLaunchPreparationV1? {
        owner.lastSession
    }

    var isTransitionInProgress: Bool {
        owner.isTransitionInProgress
    }

    var hasActiveSession: Bool {
        owner.hasActiveSession
    }

    var activePresentation: SteamCompatibilitySessionPresentationState? {
        owner.activePresentation
    }

    var isStandardSteamLaunchReserved: Bool {
        standardSteamLaunchReservationGate.isReserved
    }

    var isWindowsExecutableLaunchReserved: Bool {
        windowsExecutableLaunchReservationGate.isReserved
    }

    func windowsExecutableLaunchReservationAvailability(
        prefixLifecycleIsBusy: Bool
    ) -> WindowsExecutableLaunchReservationAvailability {
        windowsExecutableLaunchReservationGate.availability(
            hasActiveCompatibilitySession: owner.hasActiveSession,
            compatibilityTransitionInProgress: owner.isTransitionInProgress,
            standardSteamLaunchIsReserved:
                standardSteamLaunchReservationGate.isReserved,
            prefixLifecycleIsBusy: prefixLifecycleIsBusy
        )
    }

    func reserveWindowsExecutableLaunch(
        prefixLifecycleIsBusy: Bool
    ) throws -> WindowsExecutableLaunchReservation {
        try windowsExecutableLaunchReservationGate.reserve(
            hasActiveCompatibilitySession: owner.hasActiveSession,
            compatibilityTransitionInProgress: owner.isTransitionInProgress,
            standardSteamLaunchIsReserved:
                standardSteamLaunchReservationGate.isReserved,
            prefixLifecycleIsBusy: prefixLifecycleIsBusy
        )
    }

    func releaseWindowsExecutableLaunchReservation(
        _ reservation: WindowsExecutableLaunchReservation
    ) {
        windowsExecutableLaunchReservationGate.release(reservation)
    }

    func prepareSteamSession(
        recipe: SteamCompatibilityLaunchProfileRecipeV1,
        unresolvedManifestRootBookmark: CompatibilityUnresolvedManifestRootBookmarkV1,
        savedPreference: CompatibilitySteamLaunchPreferenceEnvelopeV1?,
        oneLaunchOverride: CompatibilitySteamLaunchOneLaunchOverrideV1,
        displaySelections: CompatibilitySteamLaunchUserSelectionsV1,
        displayFieldProvenance: [
            CompatibilitySteamLaunchOptionKindV1: CompatibilityResolvedValueProvenanceV1
        ],
        runtimeContext: SteamManagerCompatibilityLaunchContextV1,
        manifestRootAuthorizationProvider:
            any CompatibilityManifestRootAuthorizationProviderV1,
        runtimeProviderFactory:
            @MainActor (SteamManagerCompatibilityLaunchContextV1) ->
                any CompatibilityLaunchRuntimeProviderV1
    ) async throws -> CompatibilitySteamLaunchPreparationV1 {
        try windowsExecutableLaunchReservationGate
            .requireCompatibilityOrStandardMutationAllowed()
        try standardSteamLaunchReservationGate.requireCompatibilityMutationAllowed()
        try owner.beginPreparation()
        do {
            try displaySelections.validate()
            let presentation = SteamCompatibilitySessionPresentationState(
                recipeIdentity: recipe.identity,
                selections: displaySelections,
                fieldProvenance: displayFieldProvenance,
                savedPreference: savedPreference
            )
            let runtimeProvider = runtimeProviderFactory(runtimeContext)
            let coordinator = SteamCompatibilityLaunchCoordinatorV1(
                manifestRootAuthorizationProvider: manifestRootAuthorizationProvider,
                runtimeProvider: runtimeProvider
            )
            let preparation = try await coordinator.prepareSteamSession(
                recipe: recipe,
                unresolvedManifestRootBookmark: unresolvedManifestRootBookmark,
                savedPreference: savedPreference,
                oneLaunchOverride: oneLaunchOverride
            )
            try owner.commitPreparedSession(
                preparation,
                provider: runtimeProvider,
                presentation: presentation
            )
            return preparation
        } catch {
            owner.failPreparation()
            throw error
        }
    }

    func completeSteamSession() async throws -> CompatibilitySteamLaunchPreparationV1 {
        try windowsExecutableLaunchReservationGate
            .requireCompatibilityOrStandardMutationAllowed()
        try standardSteamLaunchReservationGate.requireCompatibilityMutationAllowed()
        return try await completeOwnedSteamSession(forApplicationTermination: false)
    }

    /// Completes the retained provider transaction before the application
    /// lifecycle is allowed to enter its terminating state. A provider failure
    /// deliberately leaves the exact owner and original receipt retained so a
    /// later termination attempt can retry restoration.
    func completeActiveSessionForApplicationTerminationIfNeeded()
        async throws -> CompatibilitySteamLaunchPreparationV1?
    {
        guard owner.hasActiveSession else {
            guard !owner.isTransitionInProgress else {
                throw NavigationStableSessionOwnershipError.transitionInProgress
            }
            return nil
        }
        try windowsExecutableLaunchReservationGate
            .requireCompatibilityOrStandardMutationAllowed()
        try standardSteamLaunchReservationGate.requireCompatibilityMutationAllowed()
        return try await completeOwnedSteamSession(forApplicationTermination: true)
    }

    func reserveStandardSteamLaunch(
        prefixLifecycleIsBusy: Bool
    ) throws -> StandardSteamLaunchReservation {
        try windowsExecutableLaunchReservationGate
            .requireCompatibilityOrStandardMutationAllowed()
        return try standardSteamLaunchReservationGate.reserve(
            hasActiveCompatibilitySession: owner.hasActiveSession,
            activeCompatibilitySessionIdentity: activeCompatibilitySessionIdentity,
            compatibilityTransitionInProgress: owner.isTransitionInProgress,
            prefixLifecycleIsBusy: prefixLifecycleIsBusy
        )
    }

    func reconcileCompatibilitySessionForStandardSteamLaunch(
        _ reservation: StandardSteamLaunchReservation
    ) async throws {
        guard reservation.requiresCompatibilityReconciliation else { return }
        try standardSteamLaunchReservationGate.validateExpectedCompatibilitySession(
            for: reservation,
            currentIdentity: activeCompatibilitySessionIdentity
        )
        _ = try await completeOwnedSteamSession(forApplicationTermination: false)
        owner.clearCompletedSession()
    }

    func validateStandardSteamLaunchReservation(
        _ reservation: StandardSteamLaunchReservation,
        prefixLifecycleIsBusy: Bool
    ) throws {
        try standardSteamLaunchReservationGate.validateReadyForStandardLaunch(
            reservation,
            hasActiveCompatibilitySession: owner.hasActiveSession,
            compatibilityTransitionInProgress: owner.isTransitionInProgress,
            prefixLifecycleIsBusy: prefixLifecycleIsBusy
        )
    }

    func releaseStandardSteamLaunchReservation(
        _ reservation: StandardSteamLaunchReservation
    ) {
        standardSteamLaunchReservationGate.release(reservation)
    }

    private var activeCompatibilitySessionIdentity:
        StandardSteamCompatibilitySessionIdentity?
    {
        guard owner.hasActiveSession,
              let preparation = owner.lastSession else {
            return nil
        }
        return StandardSteamCompatibilitySessionIdentity(
            receiptID: preparation.receipt.receiptID,
            requestDigest: preparation.request.canonicalDigest
        )
    }

    private func completeOwnedSteamSession(
        forApplicationTermination: Bool
    )
        async throws -> CompatibilitySteamLaunchPreparationV1
    {
        try await owner.completeActiveSession(
            validating: Self.validateCompletedSession
        ) { provider, preparation in
            let completedReceipt: CompatibilityLaunchApplicationReceiptV1
            if forApplicationTermination {
                completedReceipt = try await provider
                    .completeSteamSessionForApplicationTermination(
                        receipt: preparation.receipt
                    )
            } else {
                completedReceipt = try await provider.completeSteamSession(
                    receipt: preparation.receipt
                )
            }
            return try CompatibilitySteamLaunchPreparationV1(
                request: preparation.request,
                receipt: completedReceipt
            )
        }
    }

    func clearCompletedSession() {
        owner.clearCompletedSession()
    }

    func recordPersistedPreference(
        _ savedPreference: CompatibilitySteamLaunchPreferenceEnvelopeV1
    ) {
        guard var presentation = owner.activePresentation,
              savedPreference.payload.identity == presentation.recipeIdentity else {
            return
        }
        presentation.savedPreference = savedPreference
        owner.updateActivePresentation(presentation)
    }

    private static func validateCompletedSession(
        original: CompatibilitySteamLaunchPreparationV1,
        completed: CompatibilitySteamLaunchPreparationV1
    ) throws {
        let originalReceipt = original.receipt
        let completedReceipt = completed.receipt
        guard completed.request.canonicalDigest == original.request.canonicalDigest,
              completedReceipt.receiptID == originalReceipt.receiptID else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "completion-binding-mismatch"
            )
        }
        guard let appliedRequestDigest = originalReceipt.evidence.appliedRequestDigest,
              appliedRequestDigest == original.request.canonicalDigest,
              completedReceipt.evidence.appliedRequestDigest == appliedRequestDigest,
              let capturedBaselineDigest = originalReceipt.evidence.capturedBaselineDigest,
              completedReceipt.evidence.capturedBaselineDigest == capturedBaselineDigest else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "completion-evidence-binding-mismatch"
            )
        }
        guard let restoredBaselineDigest = completedReceipt.evidence.restoredBaselineDigest else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "completion-restoration-proof-missing"
            )
        }
        guard restoredBaselineDigest == capturedBaselineDigest else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                "completion-restoration-proof-mismatch"
            )
        }
    }
}
