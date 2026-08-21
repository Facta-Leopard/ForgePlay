import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import ForgePlay

private final class FakeGameInputProtectionAuthorization:
    GameInputProtectionAuthorizing,
    @unchecked Sendable {
    var currentStatus: GameInputProtectionAuthorizationStatus
    private(set) var requestCount = 0
    private(set) var statusCount = 0

    init(_ status: GameInputProtectionAuthorizationStatus) {
        currentStatus = status
    }

    func status() -> GameInputProtectionAuthorizationStatus {
        statusCount += 1
        return currentStatus
    }

    func request() -> Bool {
        requestCount += 1
        return currentStatus == .authorized
    }
}

@MainActor
private final class FakeGameInputProtectionTap: GameInputProtectionTap {
    var isEnabled = true
    var enableMakesTapEnabled = true
    private(set) var enableCount = 0
    private(set) var invalidateCount = 0

    func enable() {
        enableCount += 1
        isEnabled = enableMakesTapEnabled
    }

    func invalidate() {
        invalidateCount += 1
        isEnabled = false
    }
}

@MainActor
private final class FakeGameInputProtectionTapFactory:
    GameInputProtectionTapCreating {
    let tap = FakeGameInputProtectionTap()
    var permitsCreation = true
    var onMake: (() -> Void)?
    private(set) var makeCount = 0
    private(set) var handler:
        ((GameInputProtectionTapSignal) -> GameInputProtectionEventDisposition)?

    func makeTap(
        handler: @escaping (GameInputProtectionTapSignal) ->
            GameInputProtectionEventDisposition
    ) -> GameInputProtectionTap? {
        makeCount += 1
        self.handler = handler
        onMake?()
        return permitsCreation ? tap : nil
    }

    func send(
        _ signal: GameInputProtectionTapSignal
    ) -> GameInputProtectionEventDisposition {
        handler?(signal) ?? .suppress
    }
}

@MainActor
private final class FakeGameInputPointerVisibilityDriver:
    GameInputPointerVisibilityDriving {
    var hideResults: [CGError] = [.success]
    var showResults: [CGError] = [.success]
    private(set) var hideCount = 0
    private(set) var showCount = 0

    func hidePointer() -> CGError {
        hideCount += 1
        guard !hideResults.isEmpty else { return .success }
        return hideResults.removeFirst()
    }

    func showPointer() -> CGError {
        showCount += 1
        guard !showResults.isEmpty else { return .success }
        return showResults.removeFirst()
    }
}

@MainActor
private final class FakeGameInputPointerRestorationCoordinator:
    GameInputPointerRestorationCoordinating {
    private(set) var retainedDrivers: [GameInputPointerVisibilityDriving] = []

    func retainRestorationOwnership(
        for pointerVisibilityDriver: GameInputPointerVisibilityDriving
    ) {
        retainedDrivers.append(pointerVisibilityDriver)
    }
}

@MainActor
private final class FakeGameInputModifierReleaseEmitter:
    GameInputModifierReleaseEmitting {
    var results: [GameInputModifierReleaseEmissionResult] = [
        .submittedNoConsumptionReadback
    ]
    var afterEmission: ((Int) -> Void)?
    private(set) var emissions:
        [(event: GameInputProtectionEvent, processIdentifier: pid_t)] = []

    func emitRelease(
        _ event: GameInputProtectionEvent,
        to processIdentifier: pid_t
    ) -> GameInputModifierReleaseEmissionResult {
        emissions.append((event, processIdentifier))
        afterEmission?(emissions.count)
        guard !results.isEmpty else {
            return .submittedNoConsumptionReadback
        }
        return results.removeFirst()
    }
}

@MainActor
private final class FakeGameInputModifierRestorationCoordinator:
    GameInputModifierRestorationCoordinating {
    private(set) var attempts: [Attempt] = []

    func retainRestorationOwnership(attempt: @escaping Attempt) {
        attempts.append(attempt)
    }

    @discardableResult
    func runFirstAttempt() -> Bool? {
        guard !attempts.isEmpty else { return nil }
        let result = attempts[0]()
        if result { attempts.removeFirst() }
        return result
    }
}

@MainActor
private final class FakeGameInputPointerHideFailurePublisher:
    GameInputProtectionPointerHideFailurePublishing {
    private(set) var events: [GameInputProtectionPointerHideFailureEvent] = []

    func publish(_ event: GameInputProtectionPointerHideFailureEvent) {
        events.append(event)
    }
}

private final class FakeGameInputProtectionProcessTargetProvider:
    GameInputProtectionProcessTargetProviding {
    var frontmostProcessIdentifier: pid_t?
    var processGroups: [pid_t: pid_t] = [:]
    private var frontmostHandler:
        (@MainActor @Sendable (pid_t?) -> Void)?

    func frontmostApplicationProcessIdentifier() -> pid_t? {
        frontmostProcessIdentifier
    }

    func processGroupIdentifier(for processIdentifier: pid_t) -> pid_t? {
        processGroups[processIdentifier]
    }

    func startFrontmostApplicationMonitoring(
        _ handler: @escaping @MainActor @Sendable (pid_t?) -> Void
    ) {
        frontmostHandler = handler
    }

    func stopFrontmostApplicationMonitoring() {
        frontmostHandler = nil
    }

    func notifyFrontmostApplicationChanged() {
        frontmostHandler?(frontmostProcessIdentifier)
    }
}

@MainActor
private final class SequencedRestoreGameInputProtectionDriver:
    GameInputProtectionDriving {
    private var restoreResults: [Bool]
    private var terminalFailureHandler:
        GameInputProtectionTerminalFailureHandler?
    private(set) var restoreCallCount = 0

    init(restoreResults: [Bool]) {
        self.restoreResults = restoreResults
    }

    var requiresLifecycleRetention: Bool { true }

    func prepare(policy: GameInputProtectionPolicy) throws {}

    func bindManagedProcess(processIdentifier: pid_t) throws {}

    func applicationReceipt() throws -> GameInputProtectionApplicationReceipt {
        GameInputProtectionApplicationReceipt(
            policy: .disabled,
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

    func setTerminalFailureHandler(
        _ handler: GameInputProtectionTerminalFailureHandler?
    ) {
        terminalFailureHandler = handler
    }

    func setPointerHideFailureHandler(
        _ handler: GameInputProtectionPointerHideFailureHandler?
    ) {}

    func sendTerminalFailure(_ failure: GameInputProtectionTerminalFailure) {
        terminalFailureHandler?(failure)
    }

    func restore() -> Bool {
        restoreCallCount += 1
        guard !restoreResults.isEmpty else { return true }
        return restoreResults.removeFirst()
    }
}

private final class GameInputProtectionLifetimeOwner {}

private final class SteamManagerRestorationMonitorCancellationProbe:
    @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var cancellationObserved = false

    var hasEntered: Bool {
        lock.withLock { entered }
    }

    var hasObservedCancellation: Bool {
        lock.withLock { cancellationObserved }
    }

    func waitUntilCancelled() async throws -> Bool {
        lock.withLock { entered = true }
        do {
            try await Task.sleep(for: .seconds(3_600))
            return false
        } catch {
            lock.withLock { cancellationObserved = true }
            throw error
        }
    }
}

@MainActor
private final class GameInputProtectionLifetimeBox {
    var owner: GameInputProtectionLifetimeOwner? =
        GameInputProtectionLifetimeOwner()
    weak var observedOwner: GameInputProtectionLifetimeOwner?

    init() {
        observedOwner = owner
    }
}

private struct MaskedGameInputCommitFailure: Error {}

@MainActor
private final class GameInputProtectionClaimRegistryBox {
    var registry = GameInputProtectionContainmentClaimRegistry()
    private(set) var isWaiting = false
    private(set) var cleanupPhases:
        [GameInputProtectionTerminalContainmentState.Phase] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func waitOnce() async {
        guard !isWaiting else { return }
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        isWaiting = false
    }

    func resumeWait() {
        continuation?.resume()
        continuation = nil
    }

    func successfulCleanupAttempt(
        phase: GameInputProtectionTerminalContainmentState.Phase
    ) -> GameInputProtectionTerminalContainmentCoordinator.AttemptResult {
        cleanupPhases.append(phase)
        return .success
    }
}

@MainActor
private final class GameInputProtectionContainmentProbe {
    private(set) var events: [String] = []
    private(set) var isWaitingForCallerCancellation = false
    private var shutdownAttempts = 0
    private var restorationAttempts = 0
    private var sleepCallCount = 0
    private var cancellationWaitContinuation:
        CheckedContinuation<Void, Never>?

    func attempt(
        _ phase: GameInputProtectionTerminalContainmentState.Phase
    ) -> GameInputProtectionTerminalContainmentCoordinator.AttemptResult {
        switch phase {
        case .shutdown:
            shutdownAttempts += 1
            events.append("shutdown")
            return shutdownAttempts == 1
                ? .failure("managed runtime remained active")
                : .success
        case .restoration:
            restorationAttempts += 1
            events.append("quiesce-prior-monitor")
            events.append("restore-prior-state")
            return restorationAttempts == 1
                ? .failure("prior state restore failed")
                : .success
        case .complete:
            return .success
        }
    }

    func recordSleep(delay: Int) async throws {
        try Task.checkCancellation()
        events.append("sleep-\(delay)")
        sleepCallCount += 1
        if sleepCallCount == 1 {
            isWaitingForCallerCancellation = true
            await withCheckedContinuation { continuation in
                cancellationWaitContinuation = continuation
            }
            isWaitingForCallerCancellation = false
        }
        try Task.checkCancellation()
    }

    func releaseCallerCancellationWait() {
        cancellationWaitContinuation?.resume()
        cancellationWaitContinuation = nil
    }
}

@MainActor
final class GameInputProtectionTests: XCTestCase {
    func testDefaultPolicyAndStoreAreResourceFree() {
        let store = GameInputProtectionPolicyStore(
            isSupportedInCurrentBuild: true
        )

        XCTAssertEqual(store.snapshot(), .disabled)
        XCTAssertFalse(store.snapshot().isActive)

        store.update { policy in
            policy.blockAppWindowManagementShortcuts = true
        }
        XCTAssertTrue(store.snapshot().blockAppWindowManagementShortcuts)

        store.update(.disabled)
        XCTAssertEqual(store.snapshot(), .disabled)

        let unsupportedStore = GameInputProtectionPolicyStore(
            initialPolicy: GameInputProtectionPolicy(
                blockAppSwitchingShortcuts: true
            ),
            isSupportedInCurrentBuild: false
        )
        XCTAssertEqual(unsupportedStore.snapshot(), .disabled)
        unsupportedStore.update(GameInputProtectionPolicy(
            modifierMap: .recommended,
            hidePointerWhileManagedGameFrontmost: true
        ))
        XCTAssertEqual(unsupportedStore.snapshot(), .disabled)
    }

    func testDetachedHandoffDegradesPointerOnlyButNeverEventTapProtection()
        throws {
        let inactive = try SteamInputCompatibilitySession(
            cursorPolicy: .off,
            keyboardMapping: .systemDefault,
            gameInputProtectionPolicy: .disabled
        )
        XCTAssertTrue(inactive.permitsDetachedHandoffDegradation)
        XCTAssertTrue(inactive.isResourceFreeProtectionPolicy)
        XCTAssertFalse(inactive.requiresFailClosedManagedTransportBinding)

        let pointerOnly = try SteamInputCompatibilitySession(
            cursorPolicy: .off,
            keyboardMapping: .systemDefault,
            gameInputProtectionPolicy: GameInputProtectionPolicy(
                hidePointerWhileManagedGameFrontmost: true
            )
        )
        XCTAssertTrue(pointerOnly.permitsDetachedHandoffDegradation)
        XCTAssertFalse(pointerOnly.isResourceFreeProtectionPolicy)
        XCTAssertFalse(pointerOnly.requiresFailClosedManagedTransportBinding)

        let eventTap = try SteamInputCompatibilitySession(
            cursorPolicy: .off,
            keyboardMapping: .systemDefault,
            gameInputProtectionPolicy: GameInputProtectionPolicy(
                blockAppSwitchingShortcuts: true
            )
        )
        XCTAssertFalse(eventTap.permitsDetachedHandoffDegradation)
        XCTAssertFalse(eventTap.isResourceFreeProtectionPolicy)
        XCTAssertTrue(eventTap.requiresFailClosedManagedTransportBinding)
    }

    func testManyToOneModifierMapMapsKeyCodesAndFlagsBySide() {
        let modifierMap = GameInputModifierMap(
            command: .control,
            option: .control,
            control: .alt
        )
        let policy = GameInputProtectionPolicy(
            modifierMap: modifierMap
        )
        let unrelated = GameInputProtectionEventFlags(rawValue: 1 << 60)
        let source = GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.rightCommand,
            flags: [.command, .shift, unrelated]
        )

        guard case .pass(let mapped) = GameInputProtectionEventProcessor
            .process(source, policy: policy) else {
            return XCTFail("modifier events must be remapped, not suppressed")
        }

        XCTAssertEqual(mapped.keyCode, GameInputProtectionKeyCode.rightControl)
        XCTAssertTrue(mapped.flags.contains(.control))
        XCTAssertTrue(mapped.flags.contains(.shift))
        XCTAssertTrue(mapped.flags.contains(unrelated))
        XCTAssertFalse(mapped.flags.contains(.command))

        let leftControl = GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftControl,
            flags: [.control]
        )
        guard case .pass(let leftMapped) = GameInputProtectionEventProcessor
            .process(leftControl, policy: policy) else {
            return XCTFail("left modifier event must pass")
        }
        XCTAssertEqual(leftMapped.keyCode, GameInputProtectionKeyCode.leftOption)
        XCTAssertEqual(leftMapped.flags, [.option])

        let optionOnly = GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.rightOption,
            flags: [.option]
        )
        guard case .pass(let optionMapped) = GameInputProtectionEventProcessor
            .process(optionOnly, policy: policy) else {
            return XCTFail("many-to-one modifier event must pass")
        }
        XCTAssertEqual(optionMapped.keyCode, GameInputProtectionKeyCode.rightControl)
        XCTAssertEqual(optionMapped.flags, [.control])
    }

    func testDisabledModifierEventsFailClosedWithoutTrapOrStuckFlags() {
        let policy = GameInputProtectionPolicy(modifierMap: GameInputModifierMap(
            command: .disabled,
            option: .control,
            control: .alt
        ))
        let disabledCommandDown = GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: [.command]
        )
        let disabledCommandUp = GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: []
        )
        XCTAssertEqual(
            GameInputProtectionEventProcessor.process(
                disabledCommandDown,
                policy: policy
            ),
            .suppress
        )
        XCTAssertEqual(
            GameInputProtectionEventProcessor.process(
                disabledCommandUp,
                policy: policy
            ),
            .suppress
        )

        let ordinaryKeyWithCommandAndOption = GameInputProtectionEvent(
            kind: .keyDown,
            keyCode: GameInputProtectionKeyCode.q,
            flags: [.command, .option]
        )
        guard case .pass(let mapped) = GameInputProtectionEventProcessor
            .process(ordinaryKeyWithCommandAndOption, policy: policy) else {
            return XCTFail("ordinary keys must pass")
        }
        XCTAssertEqual(mapped.flags, [.control])
    }

    func testStatefulManyToOneModifierOwnershipUsesFirstDownAndLastUp()
        throws {
        let taps = FakeGameInputProtectionTapFactory()
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 4242
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: taps,
            processTargetProvider: targets,
            modifierReleaseEmitter: FakeGameInputModifierReleaseEmitter()
        )
        try controller.prepare(policy: GameInputProtectionPolicy(
            modifierMap: GameInputModifierMap(
                command: .control,
                option: .control,
                control: .alt
            )
        ))
        try controller.bindManagedProcess(processIdentifier: 4242)

        let leftCommandDown = GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: [.command]
        )
        guard case .pass(let firstDown) = taps.send(.event(leftCommandDown)) else {
            return XCTFail("first destination owner must emit down")
        }
        XCTAssertEqual(firstDown.keyCode, GameInputProtectionKeyCode.leftControl)
        XCTAssertEqual(firstDown.flags, [.control])

        XCTAssertEqual(taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftOption,
            flags: [.command, .option]
        ))), .suppress)
        XCTAssertEqual(taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: [.option]
        ))), .suppress)

        let ordinary = GameInputProtectionEvent(
            kind: .keyDown,
            keyCode: GameInputProtectionKeyCode.q,
            flags: [.option]
        )
        guard case .pass(let projectedOrdinary) = taps.send(.event(ordinary)) else {
            return XCTFail("ordinary key must pass with ledger projection")
        }
        XCTAssertEqual(projectedOrdinary.flags, [.control])

        guard case .pass(let lastUp) = taps.send(.event(
            GameInputProtectionEvent(
                kind: .flagsChanged,
                keyCode: GameInputProtectionKeyCode.leftOption,
                flags: []
            )
        )) else {
            return XCTFail("last destination owner must emit up")
        }
        XCTAssertEqual(lastUp.keyCode, GameInputProtectionKeyCode.leftControl)
        XCTAssertEqual(lastUp.flags, [])

        guard case .pass(let rightDown) = taps.send(.event(
            GameInputProtectionEvent(
                kind: .flagsChanged,
                keyCode: GameInputProtectionKeyCode.rightCommand,
                flags: [.command]
            )
        )) else {
            return XCTFail("right-side source must preserve destination side")
        }
        XCTAssertEqual(rightDown.keyCode, GameInputProtectionKeyCode.rightControl)
        XCTAssertEqual(taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.rightOption,
            flags: [.command, .option]
        ))), .suppress)
        XCTAssertEqual(taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.rightCommand,
            flags: [.option]
        ))), .suppress)
        guard case .pass(let rightUp) = taps.send(.event(
            GameInputProtectionEvent(
                kind: .flagsChanged,
                keyCode: GameInputProtectionKeyCode.rightOption,
                flags: []
            )
        )) else {
            return XCTFail("last right-side owner must release the destination side")
        }
        XCTAssertEqual(rightUp.keyCode, GameInputProtectionKeyCode.rightControl)
        XCTAssertEqual(rightUp.flags, [])
        XCTAssertTrue(controller.restore())
    }

    func testStatefulDisabledModifierSuppressesBothEdgesAndSyntheticTagBypasses()
        throws {
        let taps = FakeGameInputProtectionTapFactory()
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 4242
        let emitter = FakeGameInputModifierReleaseEmitter()
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: taps,
            processTargetProvider: targets,
            modifierReleaseEmitter: emitter
        )
        try controller.prepare(policy: GameInputProtectionPolicy(
            modifierMap: GameInputModifierMap(
                command: .disabled,
                option: .control,
                control: .alt
            ),
            blockAppWindowManagementShortcuts: true
        ))
        try controller.bindManagedProcess(processIdentifier: 4242)

        for flags: GameInputProtectionEventFlags in [.command, []] {
            XCTAssertEqual(taps.send(.event(GameInputProtectionEvent(
                kind: .flagsChanged,
                keyCode: GameInputProtectionKeyCode.leftCommand,
                flags: flags
            ))), .suppress)
        }
        let synthetic = GameInputProtectionEvent(
            kind: .keyDown,
            keyCode: GameInputProtectionKeyCode.q,
            flags: [.command],
            sourceUserData: GameInputProtectionSyntheticEventTag.sourceUserData
        )
        XCTAssertEqual(taps.send(.event(synthetic)), .pass(synthetic))
        XCTAssertTrue(controller.restore())
        XCTAssertTrue(emitter.emissions.isEmpty)
    }

    func testModifierDownFocusLossDrainsBeforePhysicalUpFailsOpen() throws {
        let taps = FakeGameInputProtectionTapFactory()
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 4242
        let emitter = FakeGameInputModifierReleaseEmitter()
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: taps,
            processTargetProvider: targets,
            modifierReleaseEmitter: emitter
        )
        try controller.prepare(policy: GameInputProtectionPolicy(
            modifierMap: .recommended
        ))
        try controller.bindManagedProcess(processIdentifier: 4242)
        _ = taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: [.command]
        )))
        let syntheticRelease = GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftControl,
            flags: [],
            sourceUserData: GameInputProtectionSyntheticEventTag.sourceUserData
        )
        XCTAssertEqual(
            taps.send(.event(syntheticRelease)),
            .pass(syntheticRelease)
        )

        targets.frontmostProcessIdentifier = nil
        targets.notifyFrontmostApplicationChanged()

        XCTAssertEqual(emitter.emissions.count, 1)
        XCTAssertEqual(
            emitter.emissions[0].event.keyCode,
            GameInputProtectionKeyCode.leftControl
        )
        XCTAssertEqual(emitter.emissions[0].event.flags, [])
        XCTAssertEqual(
            emitter.emissions[0].event.sourceUserData,
            GameInputProtectionSyntheticEventTag.sourceUserData
        )
        XCTAssertEqual(emitter.emissions[0].processIdentifier, 4242)

        let physicalUp = GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: []
        )
        XCTAssertEqual(taps.send(.event(physicalUp)), .pass(physicalUp))
        XCTAssertTrue(controller.restore())
        XCTAssertEqual(emitter.emissions.count, 1)
    }

    func testSameGroupFrontmostTransitionDrainsDownRecipientBeforeRebinding()
        throws {
        let taps = FakeGameInputProtectionTapFactory()
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.processGroups[5000] = 77
        targets.frontmostProcessIdentifier = 4242
        let emitter = FakeGameInputModifierReleaseEmitter()
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: taps,
            processTargetProvider: targets,
            modifierReleaseEmitter: emitter
        )
        try controller.prepare(policy: GameInputProtectionPolicy(
            modifierMap: .recommended
        ))
        try controller.bindManagedProcess(processIdentifier: 4242)
        _ = taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: [.command]
        )))

        targets.frontmostProcessIdentifier = 5000
        targets.notifyFrontmostApplicationChanged()

        XCTAssertEqual(emitter.emissions.count, 1)
        XCTAssertEqual(emitter.emissions[0].processIdentifier, 4242)
        XCTAssertEqual(
            emitter.emissions[0].event.keyCode,
            GameInputProtectionKeyCode.leftControl
        )
        XCTAssertEqual(emitter.emissions[0].event.flags, [])
        XCTAssertEqual(
            emitter.emissions[0].event.sourceUserData,
            GameInputProtectionSyntheticEventTag.sourceUserData
        )
        XCTAssertTrue(controller.restore())
        XCTAssertEqual(emitter.emissions.count, 1)
    }

    func testRestoreUsesRecordedDownTargetAcrossUnannouncedSameGroupChange()
        throws {
        let taps = FakeGameInputProtectionTapFactory()
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.processGroups[5000] = 77
        targets.frontmostProcessIdentifier = 4242
        let emitter = FakeGameInputModifierReleaseEmitter()
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: taps,
            processTargetProvider: targets,
            modifierReleaseEmitter: emitter
        )
        try controller.prepare(policy: GameInputProtectionPolicy(
            modifierMap: .recommended
        ))
        try controller.bindManagedProcess(processIdentifier: 4242)
        _ = taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: [.command]
        )))
        targets.frontmostProcessIdentifier = 5000

        XCTAssertTrue(controller.restore())
        XCTAssertEqual(emitter.emissions.map(\.processIdentifier), [4242])
    }

    func testTerminalDrainUsesRecordedDownTargetAcrossSameGroupChange()
        throws {
        let taps = FakeGameInputProtectionTapFactory()
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.processGroups[5000] = 77
        targets.frontmostProcessIdentifier = 4242
        let emitter = FakeGameInputModifierReleaseEmitter()
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: taps,
            processTargetProvider: targets,
            modifierReleaseEmitter: emitter
        )
        try controller.prepare(policy: GameInputProtectionPolicy(
            modifierMap: .recommended
        ))
        try controller.bindManagedProcess(processIdentifier: 4242)
        _ = taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: [.command]
        )))
        targets.frontmostProcessIdentifier = 5000

        _ = taps.send(.disabledByUserInput)

        XCTAssertEqual(emitter.emissions.map(\.processIdentifier), [4242])
        XCTAssertTrue(controller.restore())
    }

    func testSameGroupTransitionReleaseFailureTerminatesAndRetriesExactTarget()
        throws {
        let taps = FakeGameInputProtectionTapFactory()
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.processGroups[5000] = 77
        targets.frontmostProcessIdentifier = 4242
        let emitter = FakeGameInputModifierReleaseEmitter()
        emitter.results = [.failed, .submittedNoConsumptionReadback]
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: taps,
            processTargetProvider: targets,
            modifierReleaseEmitter: emitter
        )
        var failures: [GameInputProtectionTerminalFailure] = []
        controller.setTerminalFailureHandler { failures.append($0) }
        try controller.prepare(policy: GameInputProtectionPolicy(
            modifierMap: .recommended
        ))
        try controller.bindManagedProcess(processIdentifier: 4242)
        _ = taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: [.command]
        )))

        targets.frontmostProcessIdentifier = 5000
        targets.notifyFrontmostApplicationChanged()

        XCTAssertEqual(failures, [.modifierReleaseEmissionFailed(4242)])
        XCTAssertEqual(emitter.emissions.map(\.processIdentifier), [4242])
        XCTAssertTrue(controller.restore())
        XCTAssertEqual(
            emitter.emissions.map(\.processIdentifier),
            [4242, 4242]
        )
    }

    func testDeinitHandoffRetainsRecordedDownTargetAcrossSameGroupChange()
        throws {
        let taps = FakeGameInputProtectionTapFactory()
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.processGroups[5000] = 77
        targets.frontmostProcessIdentifier = 4242
        let emitter = FakeGameInputModifierReleaseEmitter()
        emitter.results = [.failed, .submittedNoConsumptionReadback]
        let coordinator = FakeGameInputModifierRestorationCoordinator()
        var controller: GameInputProtectionController? =
            GameInputProtectionController(
                authorization:
                    FakeGameInputProtectionAuthorization(.authorized),
                tapFactory: taps,
                processTargetProvider: targets,
                modifierReleaseEmitter: emitter,
                modifierRestorationCoordinator: coordinator
            )
        try controller?.prepare(policy: GameInputProtectionPolicy(
            modifierMap: .recommended
        ))
        try controller?.bindManagedProcess(processIdentifier: 4242)
        _ = taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: [.command]
        )))
        targets.frontmostProcessIdentifier = 5000

        controller = nil

        XCTAssertEqual(coordinator.attempts.count, 1)
        XCTAssertEqual(coordinator.runFirstAttempt(), true)
        XCTAssertEqual(
            emitter.emissions.map(\.processIdentifier),
            [4242, 4242]
        )
    }

    func testModifierDrainRunsOnRestoreAndTapTerminal() throws {
        for terminal in [false, true] {
            let taps = FakeGameInputProtectionTapFactory()
            let targets = FakeGameInputProtectionProcessTargetProvider()
            targets.processGroups[4242] = 77
            targets.frontmostProcessIdentifier = 4242
            let emitter = FakeGameInputModifierReleaseEmitter()
            let controller = GameInputProtectionController(
                authorization: FakeGameInputProtectionAuthorization(.authorized),
                tapFactory: taps,
                processTargetProvider: targets,
                modifierReleaseEmitter: emitter
            )
            try controller.prepare(policy: GameInputProtectionPolicy(
                modifierMap: .recommended
            ))
            try controller.bindManagedProcess(processIdentifier: 4242)
            _ = taps.send(.event(GameInputProtectionEvent(
                kind: .flagsChanged,
                keyCode: GameInputProtectionKeyCode.leftCommand,
                flags: [.command]
            )))

            if terminal {
                _ = taps.send(.disabledByUserInput)
            } else {
                XCTAssertTrue(controller.restore())
            }
            XCTAssertEqual(emitter.emissions.count, 1)
            XCTAssertEqual(
                emitter.emissions[0].event.keyCode,
                GameInputProtectionKeyCode.leftControl
            )
        }
    }

    func testModifierReleaseRevalidatesPIDGroupAndRetriesEmitterFailure()
        throws {
        let taps = FakeGameInputProtectionTapFactory()
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 4242
        let emitter = FakeGameInputModifierReleaseEmitter()
        emitter.results = [.failed, .submittedNoConsumptionReadback]
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: taps,
            processTargetProvider: targets,
            modifierReleaseEmitter: emitter
        )
        var failures: [GameInputProtectionTerminalFailure] = []
        controller.setTerminalFailureHandler { failures.append($0) }
        try controller.prepare(policy: GameInputProtectionPolicy(
            modifierMap: .recommended
        ))
        try controller.bindManagedProcess(processIdentifier: 4242)
        _ = taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: [.command]
        )))

        XCTAssertFalse(controller.restore())
        XCTAssertEqual(failures, [.modifierReleaseEmissionFailed(4242)])
        XCTAssertTrue(controller.restore())
        XCTAssertEqual(emitter.emissions.count, 2)

        let reboundTaps = FakeGameInputProtectionTapFactory()
        let reboundEmitter = FakeGameInputModifierReleaseEmitter()
        targets.processGroups[4242] = 77
        let reboundController = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: reboundTaps,
            processTargetProvider: targets,
            modifierReleaseEmitter: reboundEmitter
        )
        try reboundController.prepare(policy: GameInputProtectionPolicy(
            modifierMap: .recommended
        ))
        try reboundController.bindManagedProcess(processIdentifier: 4242)
        _ = reboundTaps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: [.command]
        )))
        targets.processGroups[4242] = 88
        XCTAssertTrue(reboundController.restore())
        XCTAssertTrue(reboundEmitter.emissions.isEmpty)
    }

    func testModifierReleaseRevalidatesBeforeEveryDestinationPost() throws {
        let taps = FakeGameInputProtectionTapFactory()
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 4242
        let emitter = FakeGameInputModifierReleaseEmitter()
        emitter.afterEmission = { count in
            if count == 1 { targets.processGroups[4242] = 88 }
        }
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: taps,
            processTargetProvider: targets,
            modifierReleaseEmitter: emitter
        )
        try controller.prepare(policy: GameInputProtectionPolicy(
            modifierMap: GameInputModifierMap(
                command: .control,
                option: .disabled,
                control: .alt
            )
        ))
        try controller.bindManagedProcess(processIdentifier: 4242)
        _ = taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: [.command]
        )))
        _ = taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftControl,
            flags: [.command, .control]
        )))

        XCTAssertTrue(controller.restore())
        XCTAssertEqual(emitter.emissions.count, 1)
    }

    func testModifierDrainPreservesSharedFlagUntilBothSidesRelease() throws {
        let taps = FakeGameInputProtectionTapFactory()
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 4242
        let emitter = FakeGameInputModifierReleaseEmitter()
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: taps,
            processTargetProvider: targets,
            modifierReleaseEmitter: emitter
        )
        try controller.prepare(policy: GameInputProtectionPolicy(
            modifierMap: GameInputModifierMap(
                command: .control,
                option: .alt,
                control: .control
            )
        ))
        try controller.bindManagedProcess(processIdentifier: 4242)
        _ = taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: [.command]
        )))
        _ = taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.rightCommand,
            flags: [.command]
        )))

        XCTAssertTrue(controller.restore())
        XCTAssertEqual(emitter.emissions.count, 2)
        XCTAssertEqual(
            emitter.emissions.map(\.event.keyCode),
            [
                GameInputProtectionKeyCode.leftControl,
                GameInputProtectionKeyCode.rightControl
            ]
        )
        XCTAssertEqual(emitter.emissions[0].event.flags, [.control])
        XCTAssertEqual(emitter.emissions[1].event.flags, [])
    }

    func testModifierReleaseOwnershipHandsOffOnCancellationDeinit()
        throws {
        let taps = FakeGameInputProtectionTapFactory()
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 4242
        let emitter = FakeGameInputModifierReleaseEmitter()
        emitter.results = [
            .failed,
            .failed,
            .submittedNoConsumptionReadback
        ]
        let coordinator = FakeGameInputModifierRestorationCoordinator()
        var controller: GameInputProtectionController? =
            GameInputProtectionController(
                authorization: FakeGameInputProtectionAuthorization(.authorized),
                tapFactory: taps,
                processTargetProvider: targets,
                modifierReleaseEmitter: emitter,
                modifierRestorationCoordinator: coordinator
            )
        try controller?.prepare(policy: GameInputProtectionPolicy(
            modifierMap: .recommended
        ))
        try controller?.bindManagedProcess(processIdentifier: 4242)
        _ = taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: [.command]
        )))

        controller = nil

        XCTAssertEqual(coordinator.attempts.count, 1)
        XCTAssertEqual(coordinator.runFirstAttempt(), false)
        XCTAssertEqual(coordinator.runFirstAttempt(), true)
        XCTAssertTrue(coordinator.attempts.isEmpty)
        XCTAssertEqual(emitter.emissions.count, 3)
    }

    func testInputOnlyRestorationPlanRejectsUnleasedPrefixMutation() {
        XCTAssertEqual(
            GameInputProtectionRestorationPlan.resolve(
                inputRequiresRetention: true,
                prefixMutationRequiresRetention: false,
                hasRestorationLease: false
            ),
            .inputOnly
        )
        XCTAssertEqual(
            GameInputProtectionRestorationPlan.resolve(
                inputRequiresRetention: true,
                prefixMutationRequiresRetention: true,
                hasRestorationLease: false
            ),
            .invalidMissingMutationLease
        )
        XCTAssertEqual(
            GameInputProtectionRestorationPlan.resolve(
                inputRequiresRetention: true,
                prefixMutationRequiresRetention: true,
                hasRestorationLease: true
            ),
            .leaseBacked
        )
    }

    func testRestorationRetryPolicyUsesBoundedExponentialBackoff() {
        XCTAssertEqual(
            (1...10).map {
                GameInputProtectionRestorationRetryPolicy.delaySeconds(
                    afterConsecutiveFailure: $0
                )
            },
            [1, 2, 4, 8, 16, 32, 60, 60, 60, 60]
        )
        XCTAssertEqual(
            GameInputProtectionRestorationRetryPolicy.delaySeconds(
                afterConsecutiveFailure: 0
            ),
            0
        )
    }

    func testPrecommitRestoreFailureInstallsMonitorAfterSynchronousCallback() {
        var events: [String] = []

        let restored = GameInputProtectionPrecommitRestorationHandoff
            .restoreOrInstallRetryOwner(
                restore: {
                    events.append("restore")
                    events.append("terminal-callback-before-insert")
                    return false
                },
                retain: { events.append("retain") },
                startMonitor: { events.append("start-monitor") }
            )

        XCTAssertFalse(restored)
        XCTAssertEqual(
            events,
            [
                "restore",
                "terminal-callback-before-insert",
                "retain",
                "start-monitor"
            ]
        )
    }

    func testPrecommitSuccessfulRestoreDoesNotRetainOrInstallMonitor() {
        var events: [String] = []

        let restored = GameInputProtectionPrecommitRestorationHandoff
            .restoreOrInstallRetryOwner(
                restore: {
                    events.append("restore")
                    return true
                },
                retain: { events.append("unexpected-retain") },
                startMonitor: { events.append("unexpected-monitor") }
            )

        XCTAssertTrue(restored)
        XCTAssertEqual(events, ["restore"])
    }

    func testPrecommitPointerShowFailureCallbackPrecedesRetryOwnerInstall()
        throws {
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 4242
        let pointer = FakeGameInputPointerVisibilityDriver()
        pointer.showResults = [.cannotComplete, .success]
        var events: [String] = []
        let session = try SteamInputCompatibilitySession(
            cursorPolicy: .off,
            keyboardMapping: .systemDefault,
            gameInputProtectionPolicy: GameInputProtectionPolicy(
                hidePointerWhileManagedGameFrontmost: true
            ),
            gameInputProtection: GameInputProtectionController(
                authorization: FakeGameInputProtectionAuthorization(.authorized),
                tapFactory: FakeGameInputProtectionTapFactory(),
                processTargetProvider: targets,
                pointerVisibilityDriver: pointer
            ),
            terminalFailureHandler: { _, failure in
                XCTAssertEqual(
                    failure,
                    .pointerVisibilityRestoreFailed(
                        CGError.cannotComplete.rawValue
                    )
                )
                events.append("terminal-callback")
            }
        )
        try session.captureBeforeLaunch()
        try session.bindManagedWineTransport(processIdentifier: 4242)

        XCTAssertFalse(
            GameInputProtectionPrecommitRestorationHandoff
                .restoreOrInstallRetryOwner(
                    restore: { session.restore() },
                    retain: { events.append("retain") },
                    startMonitor: { events.append("start-monitor") }
                )
        )
        XCTAssertEqual(
            events,
            ["terminal-callback", "retain", "start-monitor"]
        )
        XCTAssertTrue(session.restore())
    }

    func testPrecommitModifierReleaseFailureCallbackPrecedesRetryOwnerInstall()
        throws {
        let taps = FakeGameInputProtectionTapFactory()
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 4242
        let emitter = FakeGameInputModifierReleaseEmitter()
        emitter.results = [.failed, .submittedNoConsumptionReadback]
        var events: [String] = []
        let session = try SteamInputCompatibilitySession(
            cursorPolicy: .off,
            keyboardMapping: .systemDefault,
            gameInputProtectionPolicy: GameInputProtectionPolicy(
                modifierMap: .recommended
            ),
            gameInputProtection: GameInputProtectionController(
                authorization: FakeGameInputProtectionAuthorization(.authorized),
                tapFactory: taps,
                processTargetProvider: targets,
                modifierReleaseEmitter: emitter
            ),
            terminalFailureHandler: { _, failure in
                XCTAssertEqual(failure, .modifierReleaseEmissionFailed(4242))
                events.append("terminal-callback")
            }
        )
        try session.captureBeforeLaunch()
        try session.bindManagedWineTransport(processIdentifier: 4242)
        _ = taps.send(.event(GameInputProtectionEvent(
            kind: .flagsChanged,
            keyCode: GameInputProtectionKeyCode.leftCommand,
            flags: [.command]
        )))

        XCTAssertFalse(
            GameInputProtectionPrecommitRestorationHandoff
                .restoreOrInstallRetryOwner(
                    restore: { session.restore() },
                    retain: { events.append("retain") },
                    startMonitor: { events.append("start-monitor") }
                )
        )
        XCTAssertEqual(
            events,
            ["terminal-callback", "retain", "start-monitor"]
        )
        XCTAssertTrue(session.restore())
    }

    func testRestorationMonitorLoopIsCancellationAwareAndWeakDuringBackoff()
        async {
        let lifetime = GameInputProtectionLifetimeBox()
        var failures: [GameInputProtectionRestorationMonitorLoop.FailureKind] = []
        let monitor = Task { @MainActor [weak owner = lifetime.owner] in
            await GameInputProtectionRestorationMonitorLoop.run(
                observeInactivity: { [weak owner] in
                    guard owner != nil else { return .stop }
                    return .retry("observation")
                },
                restore: { XCTFail("restoration must not run"); return .stop },
                failureRecorded: { kind, _, _ in failures.append(kind) },
                sleep: { _ in
                    lifetime.owner = nil
                    XCTAssertNil(lifetime.observedOwner)
                    throw CancellationError()
                }
            )
        }

        let completed = await monitor.value
        XCTAssertFalse(completed)
        XCTAssertEqual(failures, [.observation])
        XCTAssertNil(lifetime.observedOwner)
    }

#if DEBUG
    func testProductionRestorationMonitorDoesNotRetainSteamManagerDuringWait()
        async throws {
        let probe = SteamManagerRestorationMonitorCancellationProbe()
        let runner = SafeProcessRunner(
            fileManager: FileManager(),
            sandboxEnabled: false,
            managedWineProcessJournalEnabled: false
        )
        var manager: SteamManager? = SteamManager(
            pathManager: PathManager(fileManager: FileManager()),
            runner: runner,
            fileManager: FileManager(),
            compatibilityPrefixExitWaiter: { _, _, _ in
                try await probe.waitUntilCancelled()
            }
        )
        let session = try SteamInputCompatibilitySession(
            cursorPolicy: .off,
            keyboardMapping: .systemDefault,
            gameInputProtection: SequencedRestoreGameInputProtectionDriver(
                restoreResults: [true]
            )
        )
        let prefix = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlay-Monitor-Ownership-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        manager?.debugInstallInputOnlyCompatibilityRestorationMonitor(
            session: session,
            prefix: prefix
        )
        for _ in 0..<1_000 where !probe.hasEntered {
            await Task.yield()
        }
        XCTAssertTrue(probe.hasEntered)

        weak let observedManager = manager
        manager = nil
        for _ in 0..<1_000 where observedManager != nil {
            await Task.yield()
        }
        for _ in 0..<1_000 where !probe.hasObservedCancellation {
            await Task.yield()
        }

        XCTAssertNil(observedManager)
        XCTAssertTrue(probe.hasObservedCancellation)
    }
#endif

    func testRestorationMonitorOwnerGateRejectsStaleTaskRemoval() {
        let first = UUID()
        let replacement = UUID()

        XCTAssertTrue(
            GameInputProtectionRestorationMonitorOwnerGate.permitsRemoval(
                currentToken: first,
                ownerToken: first
            )
        )
        XCTAssertFalse(
            GameInputProtectionRestorationMonitorOwnerGate.permitsRemoval(
                currentToken: replacement,
                ownerToken: first
            )
        )
        XCTAssertFalse(
            GameInputProtectionRestorationMonitorOwnerGate.permitsRemoval(
                currentToken: nil,
                ownerToken: first
            )
        )
    }

    func testRestorationMonitorLoopStopsPromptlyWhenTaskIsCancelled() async {
        var enteredSleep = false
        let monitor = Task { @MainActor in
            await GameInputProtectionRestorationMonitorLoop.run(
                observeInactivity: { .retry("transient") },
                restore: { XCTFail("restore must not run"); return .stop },
                failureRecorded: { _, _, _ in },
                sleep: { _ in
                    enteredSleep = true
                    try await Task.sleep(for: .seconds(60))
                }
            )
        }
        while !enteredSleep { await Task.yield() }

        monitor.cancel()
        let completed = await monitor.value

        XCTAssertFalse(completed)
    }

    func testRestorationMonitorLoopRetriesRestorationWithBoundedBackoff()
        async {
        var restorationAttempts = 0
        var recordedFailureCounts: [Int] = []
        var delays: [Int] = []

        let completed = await GameInputProtectionRestorationMonitorLoop.run(
            observeInactivity: { .success },
            restore: {
                restorationAttempts += 1
                return restorationAttempts == 1
                    ? .retry("release")
                    : .success
            },
            failureRecorded: { kind, count, detail in
                XCTAssertEqual(kind, .restoration)
                XCTAssertEqual(detail, "release")
                recordedFailureCounts.append(count)
            },
            sleep: { delay in delays.append(delay) }
        )

        XCTAssertTrue(completed)
        XCTAssertEqual(restorationAttempts, 2)
        XCTAssertEqual(recordedFailureCounts, [1])
        XCTAssertEqual(delays, [1])
    }

    func testBlocksRequestedAppWindowAndSwitchingGroups() {
        let policy = GameInputProtectionPolicy(
            blockAppWindowManagementShortcuts: true,
            blockAppSwitchingShortcuts: true
        )

        for keyCode in [GameInputProtectionKeyCode.q,
                        GameInputProtectionKeyCode.w,
                        GameInputProtectionKeyCode.h,
                        GameInputProtectionKeyCode.m] {
            XCTAssertSuppressed(keyCode: keyCode,
                                flags: [.command], policy: policy)
        }
        XCTAssertSuppressed(keyCode: GameInputProtectionKeyCode.tab,
                            flags: [.command], policy: policy)
        XCTAssertSuppressed(keyCode: GameInputProtectionKeyCode.tab,
                            flags: [.command, .shift], policy: policy)
        XCTAssertSuppressed(keyCode: GameInputProtectionKeyCode.space,
                            flags: [.command], policy: policy)
        XCTAssertPassed(keyCode: GameInputProtectionKeyCode.q,
                        flags: [.command, .option], policy: policy)
        XCTAssertPassed(keyCode: GameInputProtectionKeyCode.escape,
                        flags: [.command, .option], policy: policy)
        XCTAssertPassed(keyCode: GameInputProtectionKeyCode.q,
                        flags: [.command, .control], policy: policy)
    }

    func testBlocksMissionControlAndSpacesKeyboardGroupOnly() {
        let policy = GameInputProtectionPolicy(
            blockMissionControlSpaceShortcuts: true
        )
        for keyCode in [GameInputProtectionKeyCode.upArrow,
                        GameInputProtectionKeyCode.downArrow,
                        GameInputProtectionKeyCode.leftArrow,
                        GameInputProtectionKeyCode.rightArrow] {
            XCTAssertSuppressed(
                keyCode: keyCode,
                flags: [.control],
                policy: policy
            )
        }
        XCTAssertSuppressed(
            keyCode: GameInputProtectionKeyCode.missionControlF3,
            flags: [],
            policy: policy
        )
        XCTAssertSuppressed(
            keyCode: GameInputProtectionKeyCode.showDesktopF11,
            flags: [],
            policy: policy
        )
        XCTAssertPassed(
            keyCode: GameInputProtectionKeyCode.upArrow,
            flags: [.command],
            policy: policy
        )

        let projectedPolicy = GameInputProtectionPolicy(
            modifierMap: .recommended,
            blockMissionControlSpaceShortcuts: true
        )
        XCTAssertSuppressed(
            keyCode: GameInputProtectionKeyCode.upArrow,
            flags: [.command],
            policy: projectedPolicy
        )
    }

    func testSafetyChordsBypassBothFilteringAndModifierRemap() {
        let policy = GameInputProtectionPolicy(
            modifierMap: .recommended,
            blockAppWindowManagementShortcuts: true
        )
        XCTAssertPassed(
            keyCode: GameInputProtectionKeyCode.escape,
            flags: [.command, .option],
            policy: policy
        )
        XCTAssertPassed(
            keyCode: GameInputProtectionKeyCode.q,
            flags: [.command, .control],
            policy: policy
        )
    }

    func testBlocksDefaultScreenshotChordsIncludingControlVariantsOnly() {
        let policy = GameInputProtectionPolicy(
            blockDefaultScreenshotShortcuts: true
        )
        for keyCode in [
            GameInputProtectionKeyCode.digit3,
            GameInputProtectionKeyCode.digit4,
            GameInputProtectionKeyCode.digit5,
            GameInputProtectionKeyCode.digit6
        ] {
            XCTAssertSuppressed(
                keyCode: keyCode,
                flags: [.command, .shift],
                policy: policy
            )
            XCTAssertSuppressed(
                keyCode: keyCode,
                flags: [.command, .shift, .control],
                policy: policy
            )
            XCTAssertPassed(
                keyCode: keyCode,
                flags: [.command, .shift, .option],
                policy: policy
            )
        }
        XCTAssertPassed(keyCode: 19, flags: [.command, .shift], policy: policy)
    }

    func testActiveAdmissionNeverRequestsPermissionAndFailsActionably() {
        let authorization = FakeGameInputProtectionAuthorization(
            .accessibilityAndInputMonitoringRequired
        )
        let controller = GameInputProtectionController(
            authorization: authorization,
            tapFactory: FakeGameInputProtectionTapFactory(),
            processTargetProvider:
                FakeGameInputProtectionProcessTargetProvider()
        )

        XCTAssertThrowsError(try controller.prepare(policy:
            GameInputProtectionPolicy(
                blockAppWindowManagementShortcuts: true
            ))) { error in
            XCTAssertEqual(
                error as? GameInputProtectionError,
                .accessibilityAndInputMonitoringPermissionsRequired
            )
        }
        XCTAssertEqual(authorization.requestCount, 0)
    }

    func testTapCreationFailureRechecksAndReportsNewMissingGrant() {
        let authorization = FakeGameInputProtectionAuthorization(.authorized)
        let tapFactory = FakeGameInputProtectionTapFactory()
        tapFactory.permitsCreation = false
        tapFactory.onMake = {
            authorization.currentStatus = .inputMonitoringRequired
        }
        let controller = GameInputProtectionController(
            authorization: authorization,
            tapFactory: tapFactory,
            processTargetProvider:
                FakeGameInputProtectionProcessTargetProvider()
        )

        XCTAssertThrowsError(try controller.prepare(policy:
            GameInputProtectionPolicy(blockAppSwitchingShortcuts: true)
        )) { error in
            XCTAssertEqual(
                error as? GameInputProtectionError,
                .inputMonitoringPermissionRequired
            )
        }
        XCTAssertEqual(authorization.statusCount, 2)
        XCTAssertEqual(authorization.requestCount, 0)
    }

    func testTapCreationFailureStaysSpecificWhenGrantsRemainAuthorized() {
        let authorization = FakeGameInputProtectionAuthorization(.authorized)
        let tapFactory = FakeGameInputProtectionTapFactory()
        tapFactory.permitsCreation = false
        let controller = GameInputProtectionController(
            authorization: authorization,
            tapFactory: tapFactory,
            processTargetProvider:
                FakeGameInputProtectionProcessTargetProvider()
        )

        XCTAssertThrowsError(try controller.prepare(policy:
            GameInputProtectionPolicy(blockAppSwitchingShortcuts: true)
        )) { error in
            XCTAssertEqual(
                error as? GameInputProtectionError,
                .eventTapCreationFailed
            )
        }
        XCTAssertEqual(authorization.statusCount, 2)
        XCTAssertEqual(authorization.requestCount, 0)
    }

    func testPointerOnlySkipsAuthorizationAndTapAndBalancesFocusTransitions()
        throws {
        let authorization = FakeGameInputProtectionAuthorization(
            .accessibilityAndInputMonitoringRequired
        )
        let tapFactory = FakeGameInputProtectionTapFactory()
        tapFactory.permitsCreation = false
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.processGroups[5000] = 88
        targets.frontmostProcessIdentifier = 4242
        let pointer = FakeGameInputPointerVisibilityDriver()
        pointer.hideResults = [.success, .success]
        pointer.showResults = [.success, .success]
        let controller = GameInputProtectionController(
            authorization: authorization,
            tapFactory: tapFactory,
            processTargetProvider: targets,
            pointerVisibilityDriver: pointer
        )
        let policy = GameInputProtectionPolicy(
            hidePointerWhileManagedGameFrontmost: true
        )

        try controller.prepare(policy: policy)
        XCTAssertEqual(authorization.statusCount, 0)
        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertEqual(tapFactory.makeCount, 0)
        try controller.bindManagedProcess(processIdentifier: 4242)
        XCTAssertEqual(pointer.hideCount, 1)

        targets.notifyFrontmostApplicationChanged()
        XCTAssertEqual(pointer.hideCount, 1)
        targets.frontmostProcessIdentifier = nil
        targets.notifyFrontmostApplicationChanged()
        XCTAssertEqual(pointer.showCount, 1)
        targets.notifyFrontmostApplicationChanged()
        XCTAssertEqual(pointer.showCount, 1)

        targets.frontmostProcessIdentifier = 5000
        targets.notifyFrontmostApplicationChanged()
        XCTAssertEqual(pointer.hideCount, 1)
        targets.frontmostProcessIdentifier = 4242
        targets.notifyFrontmostApplicationChanged()
        XCTAssertEqual(pointer.hideCount, 2)

        let receipt = try controller.applicationReceipt()
        XCTAssertFalse(receipt.filterArmed)
        XCTAssertFalse(receipt.eventTapEnabledReadback)
        XCTAssertTrue(receipt.pointerHideRequested)
        XCTAssertTrue(receipt.pointerHideAttempted)
        XCTAssertTrue(receipt.pointerHideRequestSucceeded)
        XCTAssertFalse(receipt.pointerVisibilityReadbackAvailable)
        XCTAssertTrue(receipt.pointerHideOwned)
        XCTAssertEqual(
            receipt.scope,
            .pointerLifecycleArmedVisibilityNotObserved
        )
        XCTAssertTrue(receipt.isLifecycleAdmissionVerified)
        XCTAssertTrue(controller.requiresLifecycleRetention)

        XCTAssertTrue(controller.restore())
        XCTAssertTrue(controller.restore())
        XCTAssertEqual(pointer.showCount, 2)
    }

    func testPointerHideFailureIsNonfatalAndTruthfullyReceipted() throws {
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 4242
        let pointer = FakeGameInputPointerVisibilityDriver()
        pointer.hideResults = [.cannotComplete]
        let publisher = FakeGameInputPointerHideFailurePublisher()
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(
                .accessibilityAndInputMonitoringRequired
            ),
            tapFactory: FakeGameInputProtectionTapFactory(),
            processTargetProvider: targets,
            pointerVisibilityDriver: pointer
        )
        let session = try SteamInputCompatibilitySession(
            cursorPolicy: .off,
            keyboardMapping: .systemDefault,
            gameInputProtectionPolicy: GameInputProtectionPolicy(
                hidePointerWhileManagedGameFrontmost: true
            ),
            gameInputProtection: controller,
            pointerHideFailurePublisher: publisher
        )

        try session.captureBeforeLaunch()
        try session.bindManagedWineTransport(processIdentifier: 4242)
        let applicationReceipt = try session.applicationReceipt()
        _ = try session.applicationReceipt()
        let receipt = applicationReceipt.gameInputProtection

        XCTAssertTrue(receipt.pointerHideAttempted)
        XCTAssertFalse(receipt.pointerHideRequestSucceeded)
        XCTAssertEqual(
            receipt.pointerHideRequestResultCode,
            CGError.cannotComplete.rawValue
        )
        XCTAssertFalse(receipt.pointerHideOwned)
        XCTAssertFalse(receipt.pointerVisibilityReadbackAvailable)
        XCTAssertTrue(receipt.isLifecycleAdmissionVerified)
        XCTAssertTrue(applicationReceipt.isLifecycleAdmissionVerified)
        XCTAssertEqual(publisher.events.count, 1)
        XCTAssertEqual(
            publisher.events.first?.resultCode,
            CGError.cannotComplete.rawValue
        )
        XCTAssertTrue(session.restore())
        XCTAssertEqual(pointer.showCount, 0)
    }

    func testPointerHideFailureAfterReceiptPublishesExactlyOnce() throws {
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 4242
        let pointer = FakeGameInputPointerVisibilityDriver()
        pointer.hideResults = [.success, .cannotComplete]
        let publisher = FakeGameInputPointerHideFailurePublisher()
        let session = try SteamInputCompatibilitySession(
            cursorPolicy: .off,
            keyboardMapping: .systemDefault,
            gameInputProtectionPolicy: GameInputProtectionPolicy(
                hidePointerWhileManagedGameFrontmost: true
            ),
            gameInputProtection: GameInputProtectionController(
                authorization: FakeGameInputProtectionAuthorization(.authorized),
                tapFactory: FakeGameInputProtectionTapFactory(),
                processTargetProvider: targets,
                pointerVisibilityDriver: pointer
            ),
            pointerHideFailurePublisher: publisher
        )
        try session.captureBeforeLaunch()
        try session.bindManagedWineTransport(processIdentifier: 4242)
        XCTAssertTrue(try session.applicationReceipt().isLifecycleAdmissionVerified)
        XCTAssertTrue(publisher.events.isEmpty)

        targets.frontmostProcessIdentifier = nil
        targets.notifyFrontmostApplicationChanged()
        targets.frontmostProcessIdentifier = 4242
        targets.notifyFrontmostApplicationChanged()
        targets.notifyFrontmostApplicationChanged()

        XCTAssertEqual(publisher.events.count, 1)
        XCTAssertEqual(
            publisher.events.first?.resultCode,
            CGError.cannotComplete.rawValue
        )
        XCTAssertTrue(session.restore())
    }

    func testPointerShowFailureTerminatesOnceAndRestoreRetriesUntilSuccess()
        throws {
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 4242
        let pointer = FakeGameInputPointerVisibilityDriver()
        pointer.showResults = [.cannotComplete, .cannotComplete, .success]
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: FakeGameInputProtectionTapFactory(),
            processTargetProvider: targets,
            pointerVisibilityDriver: pointer
        )
        var terminalFailures: [GameInputProtectionTerminalFailure] = []
        controller.setTerminalFailureHandler { terminalFailures.append($0) }
        try controller.prepare(policy: GameInputProtectionPolicy(
            hidePointerWhileManagedGameFrontmost: true
        ))
        try controller.bindManagedProcess(processIdentifier: 4242)

        targets.frontmostProcessIdentifier = nil
        targets.notifyFrontmostApplicationChanged()
        targets.notifyFrontmostApplicationChanged()
        XCTAssertEqual(
            terminalFailures,
            [.pointerVisibilityRestoreFailed(CGError.cannotComplete.rawValue)]
        )
        XCTAssertEqual(pointer.showCount, 1)
        XCTAssertFalse(controller.requiresLifecycleRetention)

        XCTAssertFalse(controller.restore())
        XCTAssertEqual(pointer.showCount, 2)
        XCTAssertTrue(controller.restore())
        XCTAssertEqual(pointer.showCount, 3)
        XCTAssertTrue(controller.restore())
        XCTAssertEqual(pointer.showCount, 3)
    }

    func testPointerShowFailureDuringSessionRestorePropagatesAndRetries()
        throws {
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 4242
        let pointer = FakeGameInputPointerVisibilityDriver()
        pointer.showResults = [.cannotComplete, .success]
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: FakeGameInputProtectionTapFactory(),
            processTargetProvider: targets,
            pointerVisibilityDriver: pointer
        )
        var terminalFailures: [GameInputProtectionTerminalFailure] = []
        controller.setTerminalFailureHandler { terminalFailures.append($0) }
        try controller.prepare(policy: GameInputProtectionPolicy(
            hidePointerWhileManagedGameFrontmost: true
        ))
        try controller.bindManagedProcess(processIdentifier: 4242)

        XCTAssertFalse(controller.restore())
        XCTAssertEqual(
            terminalFailures,
            [.pointerVisibilityRestoreFailed(CGError.cannotComplete.rawValue)]
        )
        XCTAssertTrue(controller.restore())
        XCTAssertEqual(pointer.showCount, 2)
        XCTAssertEqual(terminalFailures.count, 1)
    }

    func testCombinedEventFilterAndPointerReceiptKeepsScopesDistinct() throws {
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 4242
        let taps = FakeGameInputProtectionTapFactory()
        let pointer = FakeGameInputPointerVisibilityDriver()
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: taps,
            processTargetProvider: targets,
            pointerVisibilityDriver: pointer
        )
        try controller.prepare(policy: GameInputProtectionPolicy(
            blockAppSwitchingShortcuts: true,
            hidePointerWhileManagedGameFrontmost: true
        ))
        try controller.bindManagedProcess(processIdentifier: 4242)

        let receipt = try controller.applicationReceipt()
        XCTAssertTrue(receipt.filterArmed)
        XCTAssertTrue(receipt.pointerHideRequested)
        XCTAssertEqual(
            receipt.scope,
            .hostEventFilterAndPointerLifecycleArmedNoConsumptionOrVisibilityReadback
        )
        XCTAssertTrue(receipt.isLifecycleAdmissionVerified)
        _ = taps.send(.disabledByUserInput)
        XCTAssertEqual(pointer.hideCount, 1)
        XCTAssertEqual(pointer.showCount, 1)
        XCTAssertTrue(controller.restore())
        XCTAssertEqual(pointer.showCount, 1)
    }

    func testPointerPolicySnapshotIsImmutableForAdmittedSession() throws {
        let store = GameInputProtectionPolicyStore(
            initialPolicy: GameInputProtectionPolicy(
                hidePointerWhileManagedGameFrontmost: true
            ),
            isSupportedInCurrentBuild: true
        )
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(
                .accessibilityAndInputMonitoringRequired
            ),
            tapFactory: FakeGameInputProtectionTapFactory(),
            processTargetProvider: targets,
            pointerVisibilityDriver: FakeGameInputPointerVisibilityDriver()
        )
        let session = try SteamInputCompatibilitySession(
            cursorPolicy: .off,
            keyboardMapping: .systemDefault,
            gameInputProtectionPolicy: store.snapshot(),
            gameInputProtection: controller
        )
        store.update(.disabled)

        try session.captureBeforeLaunch()
        try session.bindManagedWineTransport(processIdentifier: 4242)
        let receipt = try session.applicationReceipt()
        XCTAssertTrue(
            receipt.gameInputProtection.policy
                .hidePointerWhileManagedGameFrontmost
        )
        XCTAssertEqual(store.snapshot(), .disabled)
        XCTAssertTrue(session.requiresLifecycleRetention)
        XCTAssertTrue(session.restore())
    }

    func testPointerHideIsBalancedWhenSessionIsCancelledByRelease() throws {
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 4242
        let pointer = FakeGameInputPointerVisibilityDriver()
        var session: SteamInputCompatibilitySession? =
            try SteamInputCompatibilitySession(
                cursorPolicy: .off,
                keyboardMapping: .systemDefault,
                gameInputProtectionPolicy: GameInputProtectionPolicy(
                    hidePointerWhileManagedGameFrontmost: true
                ),
                gameInputProtection: GameInputProtectionController(
                    authorization: FakeGameInputProtectionAuthorization(
                        .authorized
                    ),
                    tapFactory: FakeGameInputProtectionTapFactory(),
                    processTargetProvider: targets,
                    pointerVisibilityDriver: pointer
                )
            )
        try session?.captureBeforeLaunch()
        try session?.bindManagedWineTransport(processIdentifier: 4242)
        XCTAssertEqual(pointer.hideCount, 1)

        session = nil

        XCTAssertEqual(pointer.showCount, 1)
    }

    func testPointerRestoreOwnershipHandsOffOnceAndRetriesUntilSuccess()
        async throws {
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 4242
        let pointer = FakeGameInputPointerVisibilityDriver()
        pointer.showResults = [.cannotComplete, .cannotComplete, .success]
        let coordinator = GameInputPointerRestorationCoordinator(
            sleep: { _ in await Task.yield() },
            observesApplicationTermination: false
        )
        var session: SteamInputCompatibilitySession? =
            try SteamInputCompatibilitySession(
                cursorPolicy: .off,
                keyboardMapping: .systemDefault,
                gameInputProtectionPolicy: GameInputProtectionPolicy(
                    hidePointerWhileManagedGameFrontmost: true
                ),
                gameInputProtection: GameInputProtectionController(
                    authorization: FakeGameInputProtectionAuthorization(
                        .authorized
                    ),
                    tapFactory: FakeGameInputProtectionTapFactory(),
                    processTargetProvider: targets,
                    pointerVisibilityDriver: pointer,
                    pointerRestorationCoordinator: coordinator
                )
            )
        try session?.captureBeforeLaunch()
        try session?.bindManagedWineTransport(processIdentifier: 4242)

        session = nil
        for _ in 0..<20 where coordinator.pendingRestorationCount > 0 {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.acceptedOwnershipCount, 1)
        XCTAssertEqual(coordinator.pendingRestorationCount, 0)
        XCTAssertEqual(pointer.showCount, 3)
    }

    func testPointerRestorationHandoffAfterTerminationAttemptsShowSynchronously() {
        let pointer = FakeGameInputPointerVisibilityDriver()
        pointer.showResults = [.success]
        let coordinator = GameInputPointerRestorationCoordinator(
            sleep: { _ in await Task.yield() },
            observesApplicationTermination: false
        )

        coordinator.cancelRetriesForApplicationTermination()
        coordinator.retainRestorationOwnership(for: pointer)

        XCTAssertEqual(coordinator.acceptedOwnershipCount, 1)
        XCTAssertEqual(coordinator.pendingRestorationCount, 0)
        XCTAssertEqual(pointer.showCount, 1)
    }

    func testTargetMembershipFailsOpenAndExactManagedGroupFilters() throws {
        let authorization = FakeGameInputProtectionAuthorization(.authorized)
        let tapFactory = FakeGameInputProtectionTapFactory()
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        targets.frontmostProcessIdentifier = 5000
        targets.processGroups[5000] = 88
        let controller = GameInputProtectionController(
            authorization: authorization,
            tapFactory: tapFactory,
            processTargetProvider: targets
        )
        try controller.prepare(policy:
            GameInputProtectionPolicy(
                blockAppWindowManagementShortcuts: true
            ))
        try controller.bindManagedProcess(processIdentifier: 4242)
        let commandQ = GameInputProtectionEvent(
            kind: .keyDown,
            keyCode: GameInputProtectionKeyCode.q,
            flags: [.command]
        )

        XCTAssertEqual(tapFactory.send(.event(commandQ)), .pass(commandQ))

        targets.processGroups[5000] = 77
        targets.notifyFrontmostApplicationChanged()
        XCTAssertEqual(tapFactory.send(.event(commandQ)), .suppress)
        XCTAssertEqual(tapFactory.send(.event(GameInputProtectionEvent(
            kind: .keyUp,
            keyCode: GameInputProtectionKeyCode.q,
            flags: []
        ))), .suppress)
    }

    func testManagedTargetMustUseAProcessGroupIsolatedFromForgePlay() throws {
        let authorization = FakeGameInputProtectionAuthorization(.authorized)
        let tapFactory = FakeGameInputProtectionTapFactory()
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = getpgrp()
        let controller = GameInputProtectionController(
            authorization: authorization,
            tapFactory: tapFactory,
            processTargetProvider: targets
        )
        try controller.prepare(policy: GameInputProtectionPolicy(
            blockAppWindowManagementShortcuts: true
        ))

        XCTAssertThrowsError(
            try controller.bindManagedProcess(processIdentifier: 4242)
        ) { error in
            XCTAssertEqual(
                error as? GameInputProtectionError,
                .managedProcessBindingReadbackFailed(4242)
            )
        }
        XCTAssertTrue(controller.requiresLifecycleRetention)
        XCTAssertTrue(controller.restore())
        XCTAssertEqual(tapFactory.tap.invalidateCount, 1)
    }

    func testReceiptProvesArmedHostFilterNotChildConsumption() throws {
        let authorization = FakeGameInputProtectionAuthorization(.authorized)
        let tapFactory = FakeGameInputProtectionTapFactory()
        let targets = FakeGameInputProtectionProcessTargetProvider()
        targets.processGroups[4242] = 77
        let controller = GameInputProtectionController(
            authorization: authorization,
            tapFactory: tapFactory,
            processTargetProvider: targets
        )
        let session = try SteamInputCompatibilitySession(
            cursorPolicy: .off,
            keyboardMapping: .systemDefault,
            gameInputProtectionPolicy:
                GameInputProtectionPolicy(
                    blockAppSwitchingShortcuts: true
                ),
            gameInputProtection: controller
        )

        try session.captureBeforeLaunch()
        try session.bindManagedWineTransport(processIdentifier: 4242)
        let receipt = try session.applicationReceipt()

        XCTAssertEqual(receipt.keyboard.requestedPreset, .systemDefault)
        XCTAssertNil(receipt.keyboard.requestedPermutation)
        XCTAssertEqual(
            receipt.keyboard.disposition,
            .systemDefaultNoMutation
        )
        XCTAssertTrue(receipt.gameInputProtection.filterArmed)
        XCTAssertTrue(receipt.gameInputProtection.eventTapEnabledReadback)
        XCTAssertEqual(receipt.gameInputProtection.targetProcessIdentifier, 4242)
        XCTAssertEqual(receipt.gameInputProtection.targetProcessGroupIdentifier, 77)
        XCTAssertEqual(
            receipt.gameInputProtection.scope,
            .hostEventFilterArmedChildConsumptionNotObserved
        )
        XCTAssertTrue(receipt.isLifecycleAdmissionVerified)
        XCTAssertFalse(receipt.isResourceFreeNoMutation)
        XCTAssertTrue(session.requiresLifecycleRetention)

        XCTAssertTrue(session.restore())
        XCTAssertTrue(session.restore())
        XCTAssertEqual(tapFactory.tap.invalidateCount, 1)
    }

    func testRestoreRetriesDriverUntilRestorationActuallySucceeds() throws {
        let driver = SequencedRestoreGameInputProtectionDriver(
            restoreResults: [false, true]
        )
        let session = try SteamInputCompatibilitySession(
            cursorPolicy: .off,
            keyboardMapping: .systemDefault,
            gameInputProtectionPolicy: .disabled,
            gameInputProtection: driver
        )

        XCTAssertFalse(session.restore())
        XCTAssertFalse(session.isRestored)
        XCTAssertEqual(driver.restoreCallCount, 1)

        XCTAssertTrue(session.restore())
        XCTAssertTrue(session.isRestored)
        XCTAssertEqual(driver.restoreCallCount, 2)

        XCTAssertTrue(session.restore())
        XCTAssertEqual(driver.restoreCallCount, 2)
    }

    func testFirstTimeoutReenableRequiresImmediateSuccessfulReadback() throws {
        let authorization = FakeGameInputProtectionAuthorization(.authorized)
        let tapFactory = FakeGameInputProtectionTapFactory()
        let controller = GameInputProtectionController(
            authorization: authorization,
            tapFactory: tapFactory,
            processTargetProvider:
                FakeGameInputProtectionProcessTargetProvider()
        )
        try controller.prepare(policy:
            GameInputProtectionPolicy(blockAppSwitchingShortcuts: true))
        var terminalFailures: [GameInputProtectionTerminalFailure] = []
        controller.setTerminalFailureHandler { terminalFailures.append($0) }

        tapFactory.tap.isEnabled = false
        _ = tapFactory.send(.disabledByTimeout)
        XCTAssertTrue(tapFactory.tap.isEnabled)
        XCTAssertTrue(controller.requiresLifecycleRetention)
        XCTAssertEqual(tapFactory.tap.enableCount, 1)
        XCTAssertTrue(terminalFailures.isEmpty)
    }

    func testFailedTimeoutReadbackTerminatesAndPropagatesExactlyOnce() throws {
        let tapFactory = FakeGameInputProtectionTapFactory()
        tapFactory.tap.enableMakesTapEnabled = false
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: tapFactory,
            processTargetProvider:
                FakeGameInputProtectionProcessTargetProvider()
        )
        var terminalFailures: [GameInputProtectionTerminalFailure] = []
        let session = try SteamInputCompatibilitySession(
            cursorPolicy: .off,
            keyboardMapping: .systemDefault,
            gameInputProtectionPolicy: GameInputProtectionPolicy(
                blockAppSwitchingShortcuts: true
            ),
            gameInputProtection: controller,
            terminalFailureHandler: { _, failure in
                terminalFailures.append(failure)
            }
        )
        try session.captureBeforeLaunch()
        tapFactory.tap.isEnabled = false
        _ = tapFactory.send(.disabledByTimeout)
        _ = tapFactory.send(.disabledByTimeout)
        _ = tapFactory.send(.disabledByUserInput)
        var replacementHandlerCallCount = 0
        controller.setTerminalFailureHandler { _ in
            replacementHandlerCallCount += 1
        }

        XCTAssertEqual(
            terminalFailures,
            [.timeoutReenableReadbackFailed]
        )
        XCTAssertEqual(
            session.terminalFailure,
            .timeoutReenableReadbackFailed
        )
        XCTAssertFalse(controller.requiresLifecycleRetention)
        XCTAssertEqual(tapFactory.tap.enableCount, 1)
        XCTAssertEqual(tapFactory.tap.invalidateCount, 1)
        XCTAssertEqual(replacementHandlerCallCount, 0)
        XCTAssertThrowsError(try session.requireNoTerminalFailure()) { error in
            XCTAssertEqual(
                error as? GameInputProtectionTerminalFailure,
                .timeoutReenableReadbackFailed
            )
        }
        XCTAssertTrue(session.restore())
    }

    func testRepeatedTimeoutAfterSuccessfulReenableIsTerminal() throws {
        let tapFactory = FakeGameInputProtectionTapFactory()
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: tapFactory,
            processTargetProvider:
                FakeGameInputProtectionProcessTargetProvider()
        )
        var terminalFailures: [GameInputProtectionTerminalFailure] = []
        controller.setTerminalFailureHandler { terminalFailures.append($0) }
        try controller.prepare(policy:
            GameInputProtectionPolicy(blockAppSwitchingShortcuts: true))

        tapFactory.tap.isEnabled = false
        _ = tapFactory.send(.disabledByTimeout)
        tapFactory.tap.isEnabled = false
        _ = tapFactory.send(.disabledByTimeout)

        XCTAssertEqual(terminalFailures, [.repeatedTapTimeout])
        XCTAssertEqual(tapFactory.tap.enableCount, 1)
        XCTAssertEqual(tapFactory.tap.invalidateCount, 1)
        XCTAssertFalse(controller.requiresLifecycleRetention)
    }

    func testUserDisableIsTerminalWithoutReenableLoop() throws {
        let tapFactory = FakeGameInputProtectionTapFactory()
        let controller = GameInputProtectionController(
            authorization: FakeGameInputProtectionAuthorization(.authorized),
            tapFactory: tapFactory,
            processTargetProvider:
                FakeGameInputProtectionProcessTargetProvider()
        )
        var terminalFailures: [GameInputProtectionTerminalFailure] = []
        controller.setTerminalFailureHandler { terminalFailures.append($0) }
        try controller.prepare(policy:
            GameInputProtectionPolicy(blockAppSwitchingShortcuts: true))

        _ = tapFactory.send(.disabledByUserInput)
        _ = tapFactory.send(.disabledByUserInput)

        XCTAssertEqual(terminalFailures, [.disabledByUserInput])
        XCTAssertEqual(tapFactory.tap.enableCount, 0)
        XCTAssertEqual(tapFactory.tap.invalidateCount, 1)
        XCTAssertFalse(controller.requiresLifecycleRetention)
    }

    func testForegroundAndBackgroundContainmentRetainShutdownRetryProcessEvidence() {
        for containmentOwner in ["foreground", "background"] {
            let evidence = GameInputProtectionContainmentProcessEvidence()
            let root = URL(fileURLWithPath: "/fixture/\(containmentOwner)")
            var failedShutdown = ProcessRunResult(
                actionName: "shutdownWinePrefix",
                executable: root.appending(path: "wine"),
                arguments: ["wineserver", "-k"],
                startedAt: Date(timeIntervalSince1970: 1),
                endedAt: Date(timeIntervalSince1970: 2),
                exitCode: 0,
                stdoutLog: root.appending(path: "first-stdout.log"),
                stderrLog: root.appending(path: "first-stderr.log"),
                didTimeOut: true
            )
            failedShutdown.hasProcessExitCode = false
            failedShutdown.forgePlayStatusCode = 124
            failedShutdown.outcome = .timedOut
            failedShutdown.terminationSignal = SIGKILL
            let firstRunEvidence = root.appending(path: "first-run.json")
            failedShutdown.runEvidenceLog = firstRunEvidence
            let firstBarrierEvidence = root.appending(path: "first-barrier.json")
            failedShutdown.relatedRunEvidenceLogs = [firstBarrierEvidence]
            let retainedFailure = evidence.preparingForFinalization(failedShutdown)
            evidence.recordFinalized(retainedFailure)

            var successfulRetry = ProcessRunResult(
                actionName: "shutdownWinePrefix",
                executable: root.appending(path: "wine"),
                arguments: ["wineserver", "-k"],
                startedAt: Date(timeIntervalSince1970: 3),
                endedAt: Date(timeIntervalSince1970: 4),
                exitCode: 0,
                stdoutLog: root.appending(path: "retry-stdout.log"),
                stderrLog: root.appending(path: "retry-stderr.log"),
                didTimeOut: false
            )
            successfulRetry.outcome = .exited
            successfulRetry.runEvidenceLog = root.appending(path: "retry-run.json")
            let retainedRetry = evidence.preparingForFinalization(successfulRetry)
            evidence.recordFinalized(retainedRetry)

            XCTAssertEqual(
                retainedRetry.relatedRunEvidenceLogs,
                [firstBarrierEvidence, firstRunEvidence],
                containmentOwner
            )
            let diagnosticError = GameInputProtectionContainmentDiagnosticError(
                underlyingError: GameInputProtectionTerminalFailure
                    .disabledByUserInput,
                diagnosticProcessResults: evidence.processResults
            )
            XCTAssertEqual(
                diagnosticProcessRunResults(from: diagnosticError),
                [retainedFailure, retainedRetry],
                containmentOwner
            )
        }
    }

    func testTerminalContainmentStateRetriesShutdownBeforeRestoration() {
        var state = GameInputProtectionTerminalContainmentState()
        XCTAssertEqual(state.phase, .shutdown)
        XCTAssertEqual(state.recordFailure(), 1)
        XCTAssertEqual(state.recordFailure(), 2)
        XCTAssertEqual(state.phase, .shutdown)

        state.recordSuccess()
        XCTAssertEqual(state.phase, .restoration)
        XCTAssertEqual(state.consecutiveFailures, 0)
        XCTAssertEqual(state.recordFailure(), 1)
        XCTAssertEqual(state.phase, .restoration)

        state.recordSuccess()
        XCTAssertEqual(state.phase, .complete)
        XCTAssertEqual(state.recordFailure(), 0)
    }

    func testOnlyExactCommittedSessionPermitsBackgroundContainment() {
        let terminal = GameInputProtectionSessionIdentity()
        let different = GameInputProtectionSessionIdentity()
        XCTAssertFalse(
            GameInputProtectionCommittedSessionGate
                .permitsBackgroundContainment(
                    terminalSession: terminal,
                    committedSession: nil
                )
        )
        XCTAssertFalse(
            GameInputProtectionCommittedSessionGate
                .permitsBackgroundContainment(
                    terminalSession: terminal,
                    committedSession: different
                )
        )
        XCTAssertTrue(
            GameInputProtectionCommittedSessionGate
                .permitsBackgroundContainment(
                    terminalSession: terminal,
                    committedSession: terminal
                )
        )
        XCTAssertFalse(
            GameInputProtectionCommittedSessionGate
                .permitsBackgroundContainment(
                    terminalSession: terminal,
                    committedSession: terminal,
                    hasExistingContainment: true
                )
        )
    }

    func testContainmentClaimRegistryUnifiesOwnersAndRejectsStaleRelease() {
        var registry = GameInputProtectionContainmentClaimRegistry()
        let first: GameInputProtectionContainmentClaimToken
        switch registry.acquire(prefixKey: "prefix") {
        case .acquired(let token): first = token
        case .existing: return XCTFail("first owner must acquire")
        }
        XCTAssertEqual(
            registry.acquire(prefixKey: "prefix"),
            .existing(first)
        )
        XCTAssertTrue(registry.hasClaim(prefixKey: "prefix"))

        let stale = GameInputProtectionContainmentClaimToken()
        XCTAssertFalse(registry.release(prefixKey: "prefix", token: stale))
        XCTAssertTrue(registry.isCurrent(prefixKey: "prefix", token: first))
        XCTAssertTrue(registry.release(prefixKey: "prefix", token: first))

        guard case .acquired(let successor) =
                registry.acquire(prefixKey: "prefix") else {
            return XCTFail("successor owner must acquire")
        }
        XCTAssertNotEqual(successor, first)
        XCTAssertFalse(registry.release(prefixKey: "prefix", token: first))
        XCTAssertTrue(
            registry.isCurrent(prefixKey: "prefix", token: successor)
        )
    }

    func testDispatchAdmissionContractCoversAllThreeCallSites() {
        XCTAssertEqual(
            Set(GameInputProtectionDispatchAdmissionSite.allCases),
            Set([.initial, .bootstrapRetry, .fallbackRetry])
        )
    }

    func testClaimArrivingAfterLaunchStartBlocksEveryDispatchSite() async {
        for site in GameInputProtectionDispatchAdmissionSite.allCases {
            let box = GameInputProtectionClaimRegistryBox()
            XCTAssertFalse(box.registry.hasClaim(prefixKey: site.rawValue))
            _ = box.registry.acquire(prefixKey: site.rawValue)
            var dispatched = false
            let admission = Task { @MainActor in
                try await GameInputProtectionContainmentAdmissionWaiter.wait(
                    whileActive: {
                        box.registry.hasClaim(prefixKey: site.rawValue)
                    },
                    sleep: { try await Task.sleep(for: .seconds(60)) }
                )
                dispatched = true
            }
            await Task.yield()
            admission.cancel()
            do {
                try await admission.value
                XCTFail("\(site) dispatch admission must remain blocked")
            } catch is CancellationError {
                // Expected: no dispatch occurred after the late claim.
            } catch {
                XCTFail("unexpected \(site) admission error: \(error)")
            }
            XCTAssertFalse(dispatched)
        }
    }

    func testPrecommitTerminalDuringClaimWaitBlocksEveryDispatchSite()
        async throws {
        for site in GameInputProtectionDispatchAdmissionSite.allCases {
            let driver = SequencedRestoreGameInputProtectionDriver(
                restoreResults: [true]
            )
            let session = try SteamInputCompatibilitySession(
                cursorPolicy: .off,
                keyboardMapping: .systemDefault,
                gameInputProtectionPolicy: .disabled,
                gameInputProtection: driver
            )
            try session.captureBeforeLaunch()
            let box = GameInputProtectionClaimRegistryBox()
            guard case .acquired(let claim) =
                    box.registry.acquire(prefixKey: site.rawValue) else {
                return XCTFail("late claim must acquire for \(site)")
            }
            var dispatchReached = false
            let attempt = Task { @MainActor in
                do {
                    try await GameInputProtectionContainmentAdmissionWaiter.wait(
                        whileActive: {
                            box.registry.hasClaim(prefixKey: site.rawValue)
                        },
                        sleep: { await box.waitOnce() }
                    )
                    try session.requireNoTerminalFailure()
                    dispatchReached = true
                    return false
                } catch let failure as GameInputProtectionTerminalFailure {
                    return failure == .disabledByUserInput
                } catch {
                    XCTFail("unexpected \(site) validation error: \(error)")
                    return false
                }
            }
            while !box.isWaiting { await Task.yield() }
            driver.sendTerminalFailure(.disabledByUserInput)
            XCTAssertTrue(
                box.registry.release(prefixKey: site.rawValue, token: claim)
            )
            box.resumeWait()
            let terminalBlockedDispatch = await attempt.value
            XCTAssertTrue(terminalBlockedDispatch)
            XCTAssertFalse(dispatchReached)
        }
    }

    func testClaimReleaseWaitsForLocalAndRendererRollback() async throws {
        let box = GameInputProtectionClaimRegistryBox()
        guard case .acquired(let token) =
                box.registry.acquire(prefixKey: "prefix") else {
            return XCTFail("rollback claim must acquire")
        }
        let ownership = GameInputProtectionPostDispatchRollbackOwnership(
            requiresRendererRollback: true
        )
        let admission = Task { @MainActor in
            try await GameInputProtectionContainmentAdmissionWaiter.wait(
                whileActive: {
                    box.registry.hasClaim(prefixKey: "prefix")
                },
                sleep: { await box.waitOnce() }
            )
            return true
        }
        while !box.isWaiting { await Task.yield() }

        ownership.markLocalInputAndControllerRollbackCompleted()
        XCTAssertFalse(
            GameInputProtectionPostDispatchClaimReleaseGate
                .releaseIfRollbackCompleted(
                    ownership: ownership,
                    registry: &box.registry,
                    prefixKey: "prefix",
                    token: token
                )
        )
        XCTAssertTrue(box.registry.hasClaim(prefixKey: "prefix"))

        ownership.markRendererRollbackCompleted()
        XCTAssertTrue(
            GameInputProtectionPostDispatchClaimReleaseGate
                .releaseIfRollbackCompleted(
                    ownership: ownership,
                    registry: &box.registry,
                    prefixKey: "prefix",
                    token: token
                )
        )
        box.resumeWait()
        let admissionCompleted = try await admission.value
        XCTAssertTrue(admissionCompleted)
        XCTAssertFalse(box.registry.hasClaim(prefixKey: "prefix"))
    }

    func testExistingClaimWaitAcquiresFreshClaimAndRunsOwnCleanup() async {
        let box = GameInputProtectionClaimRegistryBox()
        guard case .acquired(let owner) =
                box.registry.acquire(prefixKey: "prefix") else {
            return XCTFail("owner must acquire")
        }
        let ownership = GameInputProtectionPostDispatchRollbackOwnership(
            requiresRendererRollback: false
        )
        let foreground = Task { @MainActor in
            let freshToken = await GameInputProtectionForegroundClaimAcquirer
                .acquireFreshClaim(
                    acquire: {
                        box.registry.acquire(prefixKey: "prefix")
                    },
                    waitForCompletion: { existingToken in
                        await GameInputProtectionContainmentClaimCompletionWaiter
                            .wait(
                                whileCurrent: {
                                    box.registry.isCurrent(
                                        prefixKey: "prefix",
                                        token: existingToken
                                    )
                                },
                                sleep: { await box.waitOnce() }
                            )
                    }
                )
            let cleanup = await
                GameInputProtectionForegroundContainmentCleanup.run(
                    attempt: { phase in
                        if phase == .restoration {
                            ownership
                                .markLocalInputAndControllerRollbackCompleted()
                        }
                        return box.successfulCleanupAttempt(phase: phase)
                    },
                    failureRecorded: { _, _ in },
                    cleanupFinished: { completed in
                        guard completed else { return }
                        GameInputProtectionPostDispatchClaimReleaseGate
                            .releaseIfRollbackCompleted(
                                ownership: ownership,
                                registry: &box.registry,
                                prefixKey: "prefix",
                                token: freshToken
                            )
                    }
                )
            return (freshToken, cleanup)
        }
        while !box.isWaiting { await Task.yield() }
        foreground.cancel()
        XCTAssertTrue(
            box.registry.release(prefixKey: "prefix", token: owner)
        )
        box.resumeWait()
        let (freshToken, result) = await foreground.value
        XCTAssertNotEqual(freshToken, owner)
        XCTAssertTrue(result.cleanupCompleted)
        XCTAssertTrue(result.callerCancellationObserved)
        XCTAssertFalse(box.registry.hasClaim(prefixKey: "prefix"))
        XCTAssertEqual(box.cleanupPhases, [.shutdown, .restoration])
    }

    func testTerminalFailureMasksCommitFailureAfterThrowingAwaitInterleaving()
        async {
        var sessionTerminalFailure: GameInputProtectionTerminalFailure?
        do {
            await Task.yield()
            sessionTerminalFailure = .timeoutReenableReadbackFailed
            throw MaskedGameInputCommitFailure()
        } catch {
            let resolution = GameInputProtectionCommitFailureResolver.resolve(
                sessionTerminalFailure: sessionTerminalFailure,
                commitFailure: error,
                technicalDescription: { _ in "masked-commit-failure" }
            )
            XCTAssertEqual(
                resolution,
                GameInputProtectionCommitFailureResolution(
                    terminalFailure: .timeoutReenableReadbackFailed,
                    maskedCommitFailureTechnicalDescription:
                        "masked-commit-failure"
                )
            )
            guard let resolution else {
                return XCTFail("terminal failure must resolve")
            }
            let prioritized = GameInputProtectionTerminalFailurePriority.error(
                terminalFailure: resolution.terminalFailure,
                cleanupCompleted: true,
                callerCancellationObserved: false,
                maskedCommitFailureTechnicalDescription:
                    resolution.maskedCommitFailureTechnicalDescription
            )
            guard let composite = prioritized as?
                    GameInputProtectionTerminalCleanupError else {
                return XCTFail("masked error must preserve terminal priority")
            }
            XCTAssertEqual(
                composite.terminalFailure,
                .timeoutReenableReadbackFailed
            )
            XCTAssertEqual(
                composite.maskedCommitFailureTechnicalDescription,
                "masked-commit-failure"
            )
        }
    }

    func testNonterminalCommitFailureReturnsOriginalAfterTwoPhaseCleanup() {
        let original = MaskedGameInputCommitFailure()
        let prioritized = GameInputProtectionPostDispatchFailurePriority.error(
            originalCommitFailure: original,
            originalFailureTechnicalDescription: "original-commit",
            terminalResolution: nil,
            cleanupCompleted: true,
            callerCancellationObserved: false
        )
        XCTAssertTrue(prioritized is MaskedGameInputCommitFailure)

        let cancellationComposite =
            GameInputProtectionPostDispatchFailurePriority.error(
                originalCommitFailure: original,
                originalFailureTechnicalDescription: "original-commit",
                terminalResolution: nil,
                cleanupCompleted: true,
                callerCancellationObserved: true
            )
        guard let composite = cancellationComposite as?
                GameInputProtectionPostDispatchCleanupError else {
            return XCTFail("cancellation must preserve composite evidence")
        }
        XCTAssertEqual(
            composite.originalFailureTechnicalDescription,
            "original-commit"
        )
        XCTAssertTrue(composite.cleanupCompleted)
        XCTAssertTrue(composite.callerCancellationObserved)
    }

    func testSafetyFirstLifecycleGateQueuesOrderedEventsExactlyOnce() async {
        let gate = GameInputProtectionSafetyFirstLifecycleGate()
        var events = ["containment-task-created"]

        events.append("shutdown-attempt-admitted")
        XCTAssertTrue(
            gate.admitShutdownAttemptAndQueueLossEvent {
                events.append("loss-event-delivered")
            }
        )
        XCTAssertFalse(
            gate.admitShutdownAttemptAndQueueLossEvent {
                events.append("duplicate-loss-event")
            }
        )
        let completion = gate.queueCompletionAfterLossEvent {
            events.append("completion-event-delivered")
        }
        await completion.value
        XCTAssertEqual(
            events,
            [
                "containment-task-created",
                "shutdown-attempt-admitted",
                "loss-event-delivered",
                "completion-event-delivered"
            ]
        )
    }

    func testContainmentAdmissionWaitPropagatesCancellation() async {
        let waiter = Task { @MainActor in
            try await GameInputProtectionContainmentAdmissionWaiter.wait(
                whileActive: { true },
                sleep: { try await Task.sleep(for: .seconds(60)) }
            )
        }
        await Task.yield()
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("cancelled admission must not continue")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }

    func testContainmentAdmissionChecksCancellationWhenAlreadyInactive() async {
        let observedCancellation = await Task { @MainActor in
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            do {
                try await GameInputProtectionContainmentAdmissionWaiter.wait(
                    whileActive: { false },
                    sleep: { XCTFail("inactive admission must not sleep") }
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("unexpected cancellation error: \(error)")
                return false
            }
        }.value
        XCTAssertTrue(observedCancellation)
    }

    func testTerminalDuringPriorMonitorQuiesceShieldsShutdownAndPriorRestore()
        async {
        let probe = GameInputProtectionContainmentProbe()
        let containment = Task { @MainActor in
            do {
                try await GameInputProtectionForegroundTerminalContainment.run(
                    terminalFailure: .repeatedTapTimeout,
                    attempt: { phase in probe.attempt(phase) },
                    failureRecorded: { _, _ in },
                    sleep: { delay in
                        try await probe.recordSleep(delay: delay)
                    }
                )
            } catch let error as GameInputProtectionTerminalCleanupError {
                XCTAssertEqual(error.terminalFailure, .repeatedTapTimeout)
                XCTAssertTrue(error.cleanupCompleted)
                XCTAssertTrue(error.callerCancellationObserved)
                return true
            } catch {
                XCTFail("unexpected containment error: \(error)")
            }
            return false
        }
        while !probe.isWaitingForCallerCancellation {
            await Task.yield()
        }
        containment.cancel()
        probe.releaseCallerCancellationWait()
        let preservedTerminalFailure = await containment.value

        XCTAssertTrue(preservedTerminalFailure)
        XCTAssertEqual(
            probe.events,
            [
                "shutdown",
                "sleep-1",
                "shutdown",
                "quiesce-prior-monitor",
                "restore-prior-state",
                "sleep-1",
                "quiesce-prior-monitor",
                "restore-prior-state"
            ]
        )
    }

    func testForegroundTerminalContainmentThrowsOriginalFailureAfterCleanup()
        async {
        let claimBox = GameInputProtectionClaimRegistryBox()
        guard case .acquired(let token) =
                claimBox.registry.acquire(prefixKey: "prefix") else {
            return XCTFail("foreground cleanup must own claim")
        }
        do {
            try await GameInputProtectionForegroundTerminalContainment.run(
                terminalFailure: .disabledByUserInput,
                attempt: { _ in .success },
                failureRecorded: { _, _ in },
                cleanupFinished: { completed in
                    guard completed else { return }
                    claimBox.registry.release(
                        prefixKey: "prefix",
                        token: token
                    )
                },
                sleep: { _ in XCTFail("successful cleanup must not sleep") }
            )
        } catch let failure as GameInputProtectionTerminalFailure {
            XCTAssertEqual(failure, .disabledByUserInput)
        } catch {
            XCTFail("original terminal failure must remain primary: \(error)")
        }
        XCTAssertFalse(claimBox.registry.hasClaim(prefixKey: "prefix"))
    }

    func testContainmentCoordinatorReleasesWeakOwnerDuringRetrySleep() async {
        let box = GameInputProtectionLifetimeBox()
        let task = Task { @MainActor [weak owner = box.owner] in
            await GameInputProtectionTerminalContainmentCoordinator.run(
                attempt: { [weak owner] _ in
                    guard owner != nil else { return .cancelled }
                    return .failure("retry")
                },
                failureRecorded: { _, _ in },
                sleep: { _ in
                    box.owner = nil
                    XCTAssertNil(box.observedOwner)
                    throw CancellationError()
                }
            )
        }
        let completed = await task.value
        XCTAssertFalse(completed)
        XCTAssertNil(box.observedOwner)
    }

    private func XCTAssertSuppressed(
        keyCode: UInt16,
        flags: GameInputProtectionEventFlags,
        policy: GameInputProtectionPolicy,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let event = GameInputProtectionEvent(
            kind: .keyDown,
            keyCode: keyCode,
            flags: flags
        )
        XCTAssertEqual(
            GameInputProtectionEventProcessor.process(event, policy: policy),
            .suppress,
            file: file,
            line: line
        )
    }

    private func XCTAssertPassed(
        keyCode: UInt16,
        flags: GameInputProtectionEventFlags,
        policy: GameInputProtectionPolicy,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let event = GameInputProtectionEvent(
            kind: .keyDown,
            keyCode: keyCode,
            flags: flags
        )
        XCTAssertEqual(
            GameInputProtectionEventProcessor.process(event, policy: policy),
            .pass(event),
            file: file,
            line: line
        )
    }
}
