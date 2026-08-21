import Darwin
import CryptoKit
import SwiftData
import XCTest
@testable import ForgePlay

private final class RendererBackupCopyFailureFileManager: FileManager {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.lastPathComponent.hasSuffix(".original") {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

private final class RendererStageCopyFailureFileManager: FileManager {
    private(set) var didInjectStageFailure = false

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if !didInjectStageFailure,
           srcURL.lastPathComponent == "nvapi64.dll",
           dstURL.lastPathComponent.hasPrefix(".nvapi64.dll.restore-") {
            didInjectStageFailure = true
            throw CocoaError(.fileWriteUnknown)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

private final class RendererRestorationRetirementFailureFileManager: FileManager {
    private var isArmed = false
    private(set) var didInjectRestorationFailure = false

    func arm() {
        isArmed = true
    }

    override func removeItem(at url: URL) throws {
        if isArmed,
           !didInjectRestorationFailure,
           url.lastPathComponent.hasPrefix(".nvapi64.dll.restore-") {
            didInjectRestorationFailure = true
            throw CocoaError(.fileWriteUnknown)
        }
        try super.removeItem(at: url)
    }
}

private final class RendererBroadRestoreAdmissionProbeFileManager: FileManager {
    var blockedBroadBackupName: String?
    var transientSessionDirectory: URL?
    private(set) var broadRestoreStartedAfterTransientRetirement = false

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if let blockedBroadBackupName,
           srcURL.lastPathComponent == blockedBroadBackupName {
            if let transientSessionDirectory {
                broadRestoreStartedAfterTransientRetirement =
                    !fileExists(atPath: transientSessionDirectory.path)
            }
            throw CocoaError(.fileWriteUnknown)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

private final class ManagedPrefixInactivityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observedPrefixes: [String] = []

    func record(_ prefix: URL) {
        lock.withLock {
            observedPrefixes.append(prefix.standardizedFileURL.path)
        }
    }

    var paths: [String] {
        lock.withLock { observedPrefixes }
    }
}

private final class GameLaunchCaptureWriteFailureFileManager: FileManager {
    var blockedDirectoryPath: String?

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if let blockedDirectoryPath,
           url.standardizedFileURL.path.caseInsensitiveCompare(blockedDirectoryPath) == .orderedSame {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }
}

private enum WindowsFontV13FixtureError: Error, Equatable {
    case injected(WindowsFontLifecycleOperationKind, WindowsFontLifecycleFailureKind)
    case unexpectedRunnerAction
    case prefixMismatch
    case replacementWriteAheadMissing(String)
}

private enum NVIDIAMetalFXRegistryFixtureError: Error {
    case unexpectedAction
    case prefixMismatch
}

@MainActor
private final class WindowsFontFreshBaselineRegistryStore {
    let prefix: URL
    private var entriesByKey: [String: WindowsFontRegistryRequirement]
    private let replacementTargetIDs: Set<String>
    private(set) var writeAheadReplacementIDs: [String] = []
    var failAfterFirstReplacementTargetSet = false
    var corruptLegacyMarkerAfterFirstReplacementRestore = false
    private var didInjectReplacementFailure = false
    private var didCorruptLegacyMarker = false

    init(
        prefix: URL,
        entries: [WindowsFontRegistryRequirement]
    ) throws {
        self.prefix = prefix.standardizedFileURL
        entriesByKey = Dictionary(uniqueKeysWithValues: entries.map {
            (Self.key(path: $0.registryPath, name: $0.valueName), $0)
        })
        replacementTargetIDs = Set(
            WindowsFontCompatibilityProfileContract.supportedRegistryReplacements
                .map { $0.target.descriptorID }
        )
        try persist()
    }

    func values(for requirement: WindowsFontRegistryRequirement) -> [String]? {
        entriesByKey[
            Self.key(path: requirement.registryPath, name: requirement.valueName)
        ]?.orderedValues
    }

    func serializedSystemRegistry() throws -> Data {
        try Data(contentsOf: prefix.appending(path: "system.reg"))
    }

    func replaceFixtureValue(
        with requirement: WindowsFontRegistryRequirement
    ) throws {
        entriesByKey[Self.key(
            path: requirement.registryPath,
            name: requirement.valueName
        )] = requirement
        try persist()
    }

    func removeFixtureValue(
        for requirement: WindowsFontRegistryRequirement
    ) throws {
        entriesByKey.removeValue(forKey: Self.key(
            path: requirement.registryPath,
            name: requirement.valueName
        ))
        try persist()
    }

    func perform(
        operation: WindowsFontLifecycleOperationInstance,
        action: RunnerAction
    ) throws {
        switch action {
        case .setRegistryValue(
            _, let actionPrefix, let path, let name, let type, let value, _, _
        ):
            guard actionPrefix.standardizedFileURL == prefix else {
                throw WindowsFontV13FixtureError.prefixMismatch
            }
            guard let type else {
                throw WindowsFontV13FixtureError.unexpectedRunnerAction
            }
            let orderedValues = type == "REG_MULTI_SZ"
                ? value.components(separatedBy: "\\0")
                : [value]
            let next = WindowsFontRegistryRequirement(
                registryPath: path,
                valueName: name,
                valueType: type,
                orderedValues: orderedValues
            )
            if operation.operationKind == .registrySet {
                let journal = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: prefix.appending(
                        path: "drive_c/.forgeplay-windows-font-compatibility-v5.transaction.json"
                    ))
                ) as? [String: Any]
                let ownershipKey = journal?["operation"] as? String == "reconcile"
                    ? "plannedOwnedRegistryIDs"
                    : "committedOwnedRegistryIDs"
                let writeAheadOwnership = journal?[ownershipKey] as? [String]
                guard writeAheadOwnership?.contains(
                    operation.resourceIDOrPathID
                ) == true else {
                    throw WindowsFontV13FixtureError.replacementWriteAheadMissing(
                        operation.resourceIDOrPathID
                    )
                }
                if replacementTargetIDs.contains(next.descriptorID) {
                    writeAheadReplacementIDs.append(operation.resourceIDOrPathID)
                }
            }
            entriesByKey[Self.key(path: path, name: name)] = next
            try persist()
            if corruptLegacyMarkerAfterFirstReplacementRestore,
               operation.operationKind == .replacedRegistryRestore,
               !didCorruptLegacyMarker {
                didCorruptLegacyMarker = true
                let marker = prefix.appending(
                    path: "drive_c/ForgePlay/FontCompatibility/" +
                        "forgeplay-windows-font-compatibility-v4.txt"
                )
                try Data("drifted-v4-marker\n".utf8).write(to: marker)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: marker.path
                )
            }
            if failAfterFirstReplacementTargetSet,
               operation.operationKind == .registrySet,
               replacementTargetIDs.contains(next.descriptorID),
               !didInjectReplacementFailure {
                didInjectReplacementFailure = true
                throw WindowsFontV13FixtureError.injected(
                    .registrySet,
                    .processThrownError
                )
            }
        case .deleteRegistryValueIfPresent(
            _, let actionPrefix, let path, let name, _
        ):
            guard actionPrefix.standardizedFileURL == prefix else {
                throw WindowsFontV13FixtureError.prefixMismatch
            }
            entriesByKey.removeValue(forKey: Self.key(path: path, name: name))
            try persist()
        case .waitForWinePrefix:
            break
        default:
            throw WindowsFontV13FixtureError.unexpectedRunnerAction
        }
    }

    private static func key(path: String, name: String) -> String {
        "\(path.lowercased())\u{0}\(name.lowercased())"
    }

    private func persist() throws {
        try persistHive(
            prefix: "HKCU\\",
            url: prefix.appending(path: "user.reg")
        )
        try persistHive(
            prefix: "HKLM\\",
            url: prefix.appending(path: "system.reg")
        )
    }

    private func persistHive(prefix hivePrefix: String, url: URL) throws {
        var lines = ["WINE REGISTRY Version 2"]
        let entries = entriesByKey.values
            .filter { $0.registryPath.hasPrefix(hivePrefix) }
            .sorted {
                [$0.registryPath.lowercased(), $0.valueName.lowercased()]
                    .lexicographicallyPrecedes(
                        [$1.registryPath.lowercased(), $1.valueName.lowercased()]
                    )
            }
        for entry in entries {
            let section = String(entry.registryPath.dropFirst(hivePrefix.count))
                .replacingOccurrences(of: "\\", with: "\\\\")
            lines.append("")
            lines.append("[\(section)]")
            if entry.valueType == "REG_MULTI_SZ" {
                let value = entry.orderedValues.joined(separator: "\\0") + "\\0"
                lines.append("\"\(entry.valueName)\"=str(7):\"\(value)\"")
            } else {
                let value = entry.orderedValues.first ?? ""
                lines.append("\"\(entry.valueName)\"=\"\(value)\"")
            }
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }
}

private actor DeterministicCompatibilityPrefixExitWaiter {
    private var observations: [Bool]
    private var requestedTimeouts: [TimeInterval] = []

    init(observations: [Bool]) {
        self.observations = observations
    }

    func next(timeout: TimeInterval) -> Bool {
        requestedTimeouts.append(timeout)
        return observations.removeFirst()
    }

    func snapshot() -> (remaining: [Bool], timeouts: [TimeInterval]) {
        (observations, requestedTimeouts)
    }
}

private actor GatedCompatibilityPrefixExitWaiter {
    private var inactive = false
    private var requestedTimeouts: [TimeInterval] = []
    private var requestedPollIntervals: [TimeInterval] = []

    func next(
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) async -> Bool {
        requestedTimeouts.append(timeout)
        requestedPollIntervals.append(pollInterval)
        if timeout == 0 {
            return inactive
        }
        while !inactive {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    func markInactive() {
        inactive = true
    }

    func snapshot() -> (
        inactive: Bool,
        timeouts: [TimeInterval],
        pollIntervals: [TimeInterval]
    ) {
        (inactive, requestedTimeouts, requestedPollIntervals)
    }
}

@MainActor
private final class DetachedHandoffInputProtectionDriver:
    GameInputProtectionDriving {
    private var policy = GameInputProtectionPolicy.disabled
    private(set) var prepareCallCount = 0
    private(set) var boundProcessIdentifier: pid_t?
    private(set) var restoreCallCount = 0
    private var terminalFailureHandler:
        GameInputProtectionTerminalFailureHandler?

    var requiresLifecycleRetention: Bool {
        policy.requiresManagedTarget && restoreCallCount == 0
    }

    func prepare(policy: GameInputProtectionPolicy) throws {
        prepareCallCount += 1
        self.policy = policy
    }

    func bindManagedProcess(processIdentifier: pid_t) throws {
        guard processIdentifier > 0 else {
            throw SteamInputCompatibilitySessionError
                .modifierBridgeReadbackFailed
        }
        boundProcessIdentifier = processIdentifier
    }

    func applicationReceipt() throws -> GameInputProtectionApplicationReceipt {
        guard let boundProcessIdentifier else {
            throw SteamInputCompatibilitySessionError
                .modifierBridgeReadbackFailed
        }
        return GameInputProtectionApplicationReceipt(
            policy: policy,
            filterArmed: policy.requiresEventTap,
            eventTapEnabledReadback: policy.requiresEventTap,
            pointerHideRequested: false,
            pointerHideAttempted: false,
            pointerHideRequestSucceeded: false,
            pointerHideRequestResultCode: nil,
            pointerVisibilityReadbackAvailable: false,
            pointerHideOwned: false,
            targetProcessIdentifier: boundProcessIdentifier,
            targetProcessGroupIdentifier: boundProcessIdentifier,
            scope: policy.requiresEventTap
                ? .hostEventFilterArmedChildConsumptionNotObserved
                : .inactiveNoMutation,
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
        _: GameInputProtectionPointerHideFailureHandler?
    ) {}

    func restore() -> Bool {
        restoreCallCount += 1
        return true
    }
}

@MainActor
private final class DeterministicControllerInventoryProvider {
    private var inventories: [ControllerCompatibilityInventory]

    init(_ inventories: [ControllerCompatibilityInventory]) {
        self.inventories = inventories
    }

    func next() -> ControllerCompatibilityInventory {
        precondition(!inventories.isEmpty)
        return inventories.removeFirst()
    }
}

@MainActor
final class SteamLibraryReferenceTests: XCTestCase {
    func testInputCompatibilitySystemDefaultProducesExplicitResourceFreeReceipt() throws {
        let session = try SteamInputCompatibilitySession(
            cursorPolicy: .off,
            keyboardMapping: .systemDefault
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
        XCTAssertFalse(receipt.keyboard.bridgeEnabled)
        XCTAssertNil(receipt.keyboard.targetProcessIdentifier)
        XCTAssertNil(receipt.keyboard.readbackPermutation)
        XCTAssertFalse(receipt.keyboard.restored)
        XCTAssertTrue(receipt.isLifecycleAdmissionVerified)
        XCTAssertTrue(receipt.isResourceFreeNoMutation)
        XCTAssertFalse(session.requiresLifecycleRetention)

        XCTAssertTrue(session.restore())
        XCTAssertTrue(session.isRestored)
    }

    func testInputCompatibilityNamedAndCustomPoliciesFailAtAdmission() throws {
        let customPermutation = try ModifierKeyPermutation(
            command: .control,
            option: .alt,
            control: .windows
        )
        let unsupportedMappings: [KeyboardMappingPreference] = [
            .windowsFriendly,
            try KeyboardMappingPreference(preset: .macOSFriendly),
            try KeyboardMappingPreference(
                preset: .custom,
                customPermutation: customPermutation
            )
        ]

        for mapping in unsupportedMappings {
            XCTAssertThrowsError(
                try SteamInputCompatibilitySession(
                    cursorPolicy: .off,
                    keyboardMapping: mapping
                )
            ) { error in
                XCTAssertEqual(
                    error as? SteamInputCompatibilitySessionError,
                    .modifierBridgeUnavailable
                )
            }
        }
    }

    func testFPSBetaFailsAtAdmissionWithoutGlobalCursorMutation() throws {
        XCTAssertThrowsError(
            try SteamInputCompatibilitySession(
                cursorPolicy: .fpsRelativeCaptureBeta,
                keyboardMapping: .systemDefault
            )
        ) { error in
            XCTAssertEqual(
                error as? SteamInputCompatibilitySessionError,
                .globalCursorCaptureUnsupported
            )
        }
    }

    func testControllerAutomaticUsesResourceFreeWineIOHIDPassthroughForAnyHostInventory() throws {
        let runtime = URL(fileURLWithPath: "/not-opened/by-controller-admission")
        let zeroControllerSession = try SteamControllerCompatibilitySession(
            runtimeExecutable: runtime,
            policy: .automatic,
            inventory: ControllerCompatibilityInventory(
                macDiscoveryCount: 0,
                uniqueMacDeviceCount: 0
            )
        )
        try zeroControllerSession.bindManagedWineTransport(
            processIdentifier: 4242
        )
        let receipt = try zeroControllerSession.applicationReceipt()
        XCTAssertTrue(receipt.isResourceFreeNoMutation)
        XCTAssertFalse(receipt.staticBridgeCapability.isStaticRouteAvailable)
        XCTAssertNil(receipt.boundLauncherProcessIdentifier)
        XCTAssertFalse(zeroControllerSession.requiresLifecycleRetention)

        let detachedHandoffSession = try SteamControllerCompatibilitySession(
            runtimeExecutable: runtime,
            policy: .automatic,
            inventory: ControllerCompatibilityInventory(
                macDiscoveryCount: 0,
                uniqueMacDeviceCount: 0
            )
        )
        let detachedReceipt = try detachedHandoffSession
            .resourceFreeDetachedHandoffReceipt()
        XCTAssertTrue(detachedReceipt.isResourceFreeNoMutation)
        XCTAssertNil(detachedReceipt.boundLauncherProcessIdentifier)
        XCTAssertFalse(detachedHandoffSession.requiresLifecycleRetention)

        let connectedSession = try SteamControllerCompatibilitySession(
            runtimeExecutable: runtime,
            policy: .automatic,
            inventory: ControllerCompatibilityInventory(
                macDiscoveryCount: 1,
                uniqueMacDeviceCount: 1
            )
        )
        try connectedSession.revalidateBeforeSpawn()
        try connectedSession.bindManagedWineTransport(
            processIdentifier: 4243
        )
        let connectedReceipt = try connectedSession.applicationReceipt()
        XCTAssertEqual(
            connectedReceipt.disposition,
            .automaticWineIOHIDPassthroughNoMutation
        )
        XCTAssertEqual(connectedReceipt.macDiscoveryCount, 1)
        XCTAssertEqual(connectedReceipt.uniqueMacDeviceCount, 1)
        XCTAssertEqual(connectedReceipt.acceptedLogicalDeviceCount, 0)
        XCTAssertFalse(connectedReceipt.actualChildEnumerationVerified)
        XCTAssertTrue(connectedReceipt.isResourceFreeNoMutation)
        XCTAssertFalse(connectedSession.requiresLifecycleRetention)

        for policy in [
            ControllerCompatibilityPolicy.macOSSyntheticHID,
            .forgePlayCompatibilityBridgeBeta
        ] {
            XCTAssertThrowsError(
                try SteamControllerCompatibilitySession(
                    runtimeExecutable: runtime,
                    policy: policy,
                    inventory: ControllerCompatibilityInventory(
                        macDiscoveryCount: 0,
                        uniqueMacDeviceCount: 0
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? ControllerCompatibilityBridgeError,
                    .unsupportedPolicy(policy)
                )
            }
        }
    }

    func testControllerHotPlugRemainsResourceFreeAtEveryLaunchBoundary() throws {
        let runtime = URL(fileURLWithPath: "/not-opened/by-controller-hot-plug")
        let zero = ControllerCompatibilityInventory(
            macDiscoveryCount: 0,
            uniqueMacDeviceCount: 0
        )
        let connected = ControllerCompatibilityInventory(
            macDiscoveryCount: 1,
            uniqueMacDeviceCount: 1
        )

        let beforeSpawnProvider = DeterministicControllerInventoryProvider([
            zero,
            connected
        ])
        let beforeSpawnSession = try SteamControllerCompatibilitySession(
            runtimeExecutable: runtime,
            policy: .automatic,
            inventoryProvider: { beforeSpawnProvider.next() }
        )
        XCTAssertNoThrow(try beforeSpawnSession.revalidateBeforeSpawn())

        let bindProvider = DeterministicControllerInventoryProvider([
            zero,
            zero,
            connected
        ])
        let bindSession = try SteamControllerCompatibilitySession(
            runtimeExecutable: runtime,
            policy: .automatic,
            inventoryProvider: { bindProvider.next() }
        )
        try bindSession.revalidateBeforeSpawn()
        XCTAssertNoThrow(
            try bindSession.bindManagedWineTransport(processIdentifier: 4242)
        )

        let receiptProvider = DeterministicControllerInventoryProvider([
            zero,
            zero,
            zero,
            connected
        ])
        let receiptSession = try SteamControllerCompatibilitySession(
            runtimeExecutable: runtime,
            policy: .automatic,
            inventoryProvider: { receiptProvider.next() }
        )
        try receiptSession.revalidateBeforeSpawn()
        try receiptSession.bindManagedWineTransport(processIdentifier: 4242)
        let receipt = try receiptSession.applicationReceipt()
        XCTAssertEqual(receipt.macDiscoveryCount, 1)
        XCTAssertEqual(receipt.uniqueMacDeviceCount, 1)
        XCTAssertEqual(
            receipt.disposition,
            .automaticWineIOHIDPassthroughNoMutation
        )
        XCTAssertTrue(receipt.isResourceFreeNoMutation)
    }

    func testCompatibilityExitPollingKeepsWaitingAfterAliveIntervals() async throws {
        let waiter = DeterministicCompatibilityPrefixExitWaiter(
            observations: [false, false, true]
        )
        let manager = SteamManager(
            pathManager: PathManager(),
            runner: SafeProcessRunner(),
            compatibilityPrefixExitWaiter: { _, timeout, _ in
                await waiter.next(timeout: timeout)
            }
        )

        let exited = try await manager.waitForCompatibilityPrefixToBecomeInactive(
            URL(fileURLWithPath: "/deterministic-prefix")
        )

        XCTAssertTrue(exited)
        let snapshot = await waiter.snapshot()
        XCTAssertTrue(snapshot.remaining.isEmpty)
        XCTAssertEqual(snapshot.timeouts, [30, 30, 30])
    }

    func testDirectRestorationLeaseTransfersMutationAndReleaseOwnershipOnce() throws {
        var events: [String] = []
        let lease = SteamCompatibilityRestorationPrefixLease(
            prepareForMutation: {
                events.append("exclusive-mutation")
            },
            release: {
                events.append("release")
            }
        )

        XCTAssertFalse(lease.isTransferred)
        lease.markTransferred()
        XCTAssertTrue(lease.isTransferred)
        try lease.prepareForMutation()
        lease.release()
        lease.release()

        XCTAssertEqual(events, ["exclusive-mutation", "release"])
    }

    func testWindowsFontCompatibilityV5PreservesTahomaChainAndAddsExactCascades() {
        XCTAssertEqual(
            WindowsFontCompatibilityProfileContract.profileIdentifier,
            "forgeplay-windows-font-compatibility-v5"
        )
        XCTAssertEqual(
            WindowsFontCompatibilityProfileContract.standardSubstitutionFamilies,
            ["MS Shell Dlg"]
        )
        XCTAssertEqual(
            WindowsFontCompatibilityProfileContract.wineDefaultTahomaSubstitutionFamilies,
            ["MS Shell Dlg 2"]
        )
        XCTAssertEqual(
            WindowsFontCompatibilityProfileContract.forcedReplacementFamilies,
            ["Tahoma"]
        )
        XCTAssertEqual(
            WindowsFontCompatibilityProfileContract.fontLinkFallbackFile,
            "NanumGothic-Regular.ttf"
        )
        XCTAssertFalse(WindowsFontCompatibilityProfileContract.fontLinkFallbackFile.contains(","))
        XCTAssertEqual(WindowsFontCompatibilityProfileContract.fontPayloads.count, 12)
        XCTAssertEqual(WindowsFontCompatibilityProfileContract.registryRequirements.count, 32)
        XCTAssertEqual(
            WindowsFontCompatibilityProfileContract.linkedLatinFallbackFiles,
            [
                "NanumGothic-Regular.ttf",
                "NotoSans-Regular.ttf",
                "NotoSansCJKkr-Regular.otf",
                "NotoSansCJKjp-Regular.otf",
                "NotoSansCJKsc-Regular.otf",
                "NotoSansCJKtc-Regular.otf"
            ]
        )
        XCTAssertFalse(
            WindowsFontCompatibilityProfileContract.nanumFallbackFiles.contains(
                "NanumGothic-Regular.ttf"
            )
        )
        XCTAssertFalse(
            WindowsFontCompatibilityProfileContract.notoSansFallbackFiles.contains(
                "NotoSans-Regular.ttf"
            )
        )
    }

    func testWindowsFontCompatibilityV5PreservesV4StateButRequiresAdditiveProfile() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayFontCompatibility-\(UUID().uuidString)", directoryHint: .isDirectory)
        let prefix = temporaryRoot.appending(path: "SteamShared", directoryHint: .isDirectory)
        let fontsDirectory = prefix.appending(
            path: "drive_c/windows/Fonts",
            directoryHint: .isDirectory
        )
        let markerDirectory = prefix.appending(
            path: "drive_c/ForgePlay/FontCompatibility",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundledWine = repositoryRoot.appending(
            path: "Resources/Runners/ForgePlayRuntime/wine/bin/wine"
        )
        let bundledFonts = try XCTUnwrap(
            WindowsFontCompatibilityProfileContract.resourceDirectory(for: bundledWine)
        )
        for fileName in ["NanumGothic-Regular.ttf", "NanumGothic-Bold.ttf"] {
            try FileManager.default.copyItem(
                at: bundledFonts.appending(path: fileName),
                to: fontsDirectory.appending(path: fileName)
            )
        }

        let userRegistry = #"""
        WINE REGISTRY Version 2

        [Software\\Wine\\Fonts\\ForcedReplacements]
        "Tahoma"="NanumGothic"

        [Software\\Wine\\Fonts\\Replacements]
        "Batang"="NanumGothic"
        "BatangChe"="NanumGothic"
        "Dotum"="NanumGothic"
        "DotumChe"="NanumGothic"
        "Gulim"="NanumGothic"
        "GulimChe"="NanumGothic"
        "Gungsuh"="NanumGothic"
        "GungsuhChe"="NanumGothic"
        "Malgun Gothic"="NanumGothic"
        "Malgun Gothic Semilight"="NanumGothic"
        """# + "\n"
        try userRegistry.write(
            to: prefix.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )

        let systemRegistry = #"""
        WINE REGISTRY Version 2

        [Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts]
        "NanumGothic (TrueType)"="NanumGothic-Regular.ttf"
        "NanumGothic Bold (TrueType)"="NanumGothic-Bold.ttf"

        [Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes]
        "MS Shell Dlg"="NanumGothic"
        "MS Shell Dlg 2"="Tahoma"

        [Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink]
        "Arial"=str(7):"NanumGothic-Regular.ttf\0"
        "Microsoft Sans Serif"=str(7):"NanumGothic-Regular.ttf\0"
        "Segoe UI"=str(7):"NanumGothic-Regular.ttf\0"
        "Tahoma"=str(7):"NanumGothic-Regular.ttf\0"
        "Verdana"=str(7):"NanumGothic-Regular.ttf\0"
        """# + "\n"
        try systemRegistry.write(
            to: prefix.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )

        let contentInspection = WindowsFontCompatibilityProfileContract.inspect(
            prefix: prefix,
            requiresProfileMarker: false
        )
        let uncommittedInspection = WindowsFontCompatibilityProfileContract.inspect(prefix: prefix)

        XCTAssertFalse(contentInspection.isSatisfied)
        XCTAssertFalse(uncommittedInspection.isSatisfied)
        XCTAssertTrue(contentInspection.missingItems.contains(where: {
            $0.contains("NotoSans-Regular.ttf")
        }))
        XCTAssertTrue(uncommittedInspection.missingItems.contains(
            "forgeplay-windows-font-compatibility-v5=managed"
        ))
        XCTAssertTrue(contentInspection.appliedItems.contains(
            "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes" +
                "\\MS Shell Dlg 2=Tahoma"
        ))
        XCTAssertTrue(contentInspection.appliedItems.contains(
            "HKCU\\Software\\Wine\\Fonts\\ForcedReplacements\\Tahoma=NanumGothic"
        ))

        let markerLines = [
            "forgeplay-windows-font-compatibility-v4",
            "NanumGothic-Regular.ttf=76f45ef4a6bcff344c837c95a7dcc26e017e38b5846d5ae0cdcb5b86be2e2d31",
            "NanumGothic-Bold.ttf=21f9d3a7f1ca82ca1dc9a288e30138b4f1feb6e71fc89b5a9181fed174b6bbe2"
        ]
        try Data((markerLines.joined(separator: "\n") + "\n").utf8).write(
            to: markerDirectory.appending(path: "forgeplay-windows-font-compatibility-v4.txt"),
            options: [.atomic]
        )

        let committedInspection = WindowsFontCompatibilityProfileContract.inspect(prefix: prefix)

        XCTAssertFalse(committedInspection.isSatisfied)
        XCTAssertTrue(committedInspection.missingItems.contains(
            "forgeplay-windows-font-compatibility-v5=managed"
        ))
    }

    func testWindowsFontLegacyV4StateMigratesAtomicallyAndUninstallRestoresV4() async throws {
        let fixture = try fontV13MakeLifecycleFixture("legacy-v4-migration")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fontV13InstallExactLegacyV4Evidence(prefix: fixture.prefix)
        try fontV13InstallProductionPayloadSources(at: fixture.sourceRoot)
        let definition = WindowsFontCompatibilityProfileContract.definition
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: WindowsFontCompatibilityProfileContract
                .legacyV4RegistryRequirements
        )
        let before = try store.serializedSystemRegistry()
        let profile = fontV13FreshWineBaselineProfile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )

        let applyResult = try await profile.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(applyResult)
        for replacement in
            WindowsFontCompatibilityProfileContract.legacyV4RegistryReplacements {
            XCTAssertEqual(
                store.values(for: replacement.target),
                replacement.target.orderedValues
            )
        }
        XCTAssertEqual(
            Set(store.writeAheadReplacementIDs),
            Set(WindowsFontCompatibilityProfileContract
                .legacyV4RegistryReplacements.map(\.replacementID))
        )
        let marker = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fontV13MarkerURL(fixture.prefix))
            ) as? [String: Any]
        )
        let legacyRegistryKeys = Set(
            WindowsFontCompatibilityProfileContract.legacyV4RegistryRequirements.map {
                "\($0.registryPath.lowercased())\u{0}\($0.valueName.lowercased())"
            }
        )
        let createdRegistryIDs = definition.registryRequirements.compactMap {
            let key = "\($0.registryPath.lowercased())\u{0}\($0.valueName.lowercased())"
            return legacyRegistryKeys.contains(key) ? nil : $0.descriptorID
        }
        let expectedOwnedRegistryIDs = Set(createdRegistryIDs).union(
            WindowsFontCompatibilityProfileContract
                .legacyV4RegistryReplacements.map(\.replacementID)
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(marker["ownedRegistryIDs"] as? [String])),
            expectedOwnedRegistryIDs
        )

        let uninstallResult = try await profile.uninstall(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(uninstallResult)
        XCTAssertEqual(try store.serializedSystemRegistry(), before)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fontV13LegacyV4MarkerURL(fixture.prefix).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13MarkerURL(fixture.prefix).path
        ))
        for payload in definition.payloads where payload.sourceRole == .appNotoPack {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.prefix.appending(
                    path: "drive_c/windows/Fonts/\(payload.fileName)"
                ).path
            ))
        }
    }

    func testWindowsFontSatisfiedLaunchProvisionHashesPayloadOnceAndReusesVerifiedReadback() async throws {
        let fixture = try fontV13MakeLifecycleFixture(
            "satisfied-launch-single-hash"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let payloadData = Data("bounded-font-payload".utf8)
        let definition = fontV13Definition(payloads: [
            ("Bounded.ttf", payloadData, .runtimeNanum)
        ])
        try fontV13WritePayloadSources(
            definition,
            dataByName: ["Bounded.ttf": payloadData],
            sourceRoot: fixture.sourceRoot
        )
        var hashedDestinations: [String] = []
        let profile = fontV13Profile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            payloadHashObserver: {
                hashedDestinations.append($0.standardizedFileURL.path)
            }
        )

        let provisioned = try await profile.provisionForLaunch(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertEqual(provisioned.state, .provisionedAndVerified)

        hashedDestinations.removeAll(keepingCapacity: true)
        let reused = try await profile.provisionForLaunch(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )

        XCTAssertEqual(reused.state, .reusedVerifiedProfile)
        XCTAssertEqual(reused.baselineDigest, reused.appliedDigest)
        XCTAssertEqual(hashedDestinations.count, 1)
        XCTAssertEqual(
            hashedDestinations.first,
            fixture.prefix.appending(
                path: "drive_c/windows/Fonts/Bounded.ttf"
            ).standardizedFileURL.path
        )
    }

    func testWindowsFontLegacyV4StateWithoutExactMarkerIsZeroWriteCollision() async throws {
        let fixture = try fontV13MakeLifecycleFixture("legacy-v4-no-marker")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fontV13InstallExactLegacyV4Payloads(prefix: fixture.prefix)
        let definition = fontV13LegacyV4Definition()
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: WindowsFontCompatibilityProfileContract
                .legacyV4RegistryRequirements
        )
        let before = try store.serializedSystemRegistry()
        let profile = fontV13FreshWineBaselineProfile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )

        do {
            _ = try await profile.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("unowned legacy-looking state must not be overwritten")
        } catch WindowsFontCompatibilityProfileError.collision(let reason) {
            XCTAssertTrue(reason.contains("classification=foreign-present"), reason)
        }
        XCTAssertEqual(try store.serializedSystemRegistry(), before)
        XCTAssertTrue(profile.consumedOperations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))
    }

    func testWindowsFontLegacyV4UninstallRejectsDormantBaselineDriftBeforeWrite()
        async throws
    {
        let fixture = try fontV13MakeLifecycleFixture("legacy-v4-uninstall-drift")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fontV13InstallExactLegacyV4Evidence(prefix: fixture.prefix)
        try fontV13InstallProductionPayloadSources(at: fixture.sourceRoot)
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: WindowsFontCompatibilityProfileContract
                .legacyV4RegistryRequirements
        )
        let profile = fontV13FreshWineBaselineProfile(
            definition: WindowsFontCompatibilityProfileContract.definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )
        _ = try await profile.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        let installed = try store.serializedSystemRegistry()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fontV13LegacyV4MarkerURL(fixture.prefix).path
        )

        do {
            _ = try await profile.uninstall(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("uninstall must not overwrite a drifted dormant v4 baseline")
        } catch WindowsFontCompatibilityProfileError.recoveryConflict(let reason) {
            XCTAssertTrue(
                reason.contains("legacy-v4-font-profile-baseline-evidence-mismatch")
            )
        }
        XCTAssertEqual(try store.serializedSystemRegistry(), installed)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fontV13MarkerURL(fixture.prefix).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))
        XCTAssertTrue(profile.consumedOperations.isEmpty)
    }

    func testWindowsFontLegacyV4MigrationFailureRestoresExactBaseline() async throws {
        let fixture = try fontV13MakeLifecycleFixture("legacy-v4-rollback")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fontV13InstallExactLegacyV4Evidence(prefix: fixture.prefix)
        try fontV13InstallProductionPayloadSources(at: fixture.sourceRoot)
        let definition = WindowsFontCompatibilityProfileContract.definition
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: WindowsFontCompatibilityProfileContract
                .legacyV4RegistryRequirements
        )
        let before = try store.serializedSystemRegistry()
        store.failAfterFirstReplacementTargetSet = true
        let profile = fontV13FreshWineBaselineProfile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )

        do {
            _ = try await profile.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("failed migration must roll back to the complete v4 state")
        } catch {
            XCTAssertEqual(
                error as? WindowsFontV13FixtureError,
                .injected(.registrySet, .processThrownError)
            )
        }
        XCTAssertEqual(try store.serializedSystemRegistry(), before)
        XCTAssertEqual(store.writeAheadReplacementIDs.count, 1)
        XCTAssertTrue(profile.consumedOperations.contains {
            $0.operationKind == .replacedRegistryRestore
        })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))
        for payload in definition.payloads where payload.sourceRole == .appNotoPack {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.prefix.appending(
                    path: "drive_c/windows/Fonts/\(payload.fileName)"
                ).path
            ))
        }
    }

    func testWindowsFontLegacyV4UninstallKeepsV5EvidenceWhenRestoredBaselineDrifts()
        async throws
    {
        let fixture = try fontV13MakeLifecycleFixture("legacy-v4-post-restore-drift")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fontV13InstallExactLegacyV4Evidence(prefix: fixture.prefix)
        try fontV13InstallProductionPayloadSources(at: fixture.sourceRoot)
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: WindowsFontCompatibilityProfileContract
                .legacyV4RegistryRequirements
        )
        let profile = fontV13FreshWineBaselineProfile(
            definition: WindowsFontCompatibilityProfileContract.definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )
        _ = try await profile.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        store.corruptLegacyMarkerAfterFirstReplacementRestore = true

        do {
            _ = try await profile.uninstall(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("restored legacy evidence must be verified before v5 is released")
        } catch WindowsFontCompatibilityProfileError.uninstallIncomplete(
            let reason,
            _
        ) {
            XCTAssertTrue(
                reason.contains("legacy-v4-font-profile-baseline-restore-mismatch")
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fontV13MarkerURL(fixture.prefix).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))
    }

    func testWindowsFontLegacyV4PartialRollbackKeepsJournalWhenBaselineDrifts()
        async throws
    {
        let fixture = try fontV13MakeLifecycleFixture("legacy-v4-partial-rollback-drift")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fontV13InstallExactLegacyV4Evidence(prefix: fixture.prefix)
        try fontV13InstallProductionPayloadSources(at: fixture.sourceRoot)
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: WindowsFontCompatibilityProfileContract
                .legacyV4RegistryRequirements
        )
        let before = try store.serializedSystemRegistry()
        store.failAfterFirstReplacementTargetSet = true
        store.corruptLegacyMarkerAfterFirstReplacementRestore = true
        let profile = fontV13FreshWineBaselineProfile(
            definition: WindowsFontCompatibilityProfileContract.definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )

        do {
            _ = try await profile.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("partial rollback must retain evidence after baseline drift")
        } catch WindowsFontCompatibilityProfileError.rollbackIncomplete(
            let reason,
            _
        ) {
            XCTAssertTrue(
                reason.contains("legacy-v4-font-profile-baseline-restore-mismatch")
            )
        }
        XCTAssertEqual(try store.serializedSystemRegistry(), before)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13MarkerURL(fixture.prefix).path
        ))
    }

    func testWindowsFontLegacyV4MarkerPreventsFreshBaselineFallback() async throws {
        let fixture = try fontV13MakeLifecycleFixture("legacy-v4-no-fresh-fallback")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fontV13InstallExactLegacyV4Evidence(prefix: fixture.prefix)
        try fontV13InstallProductionPayloadSources(at: fixture.sourceRoot)
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: WindowsFontCompatibilityProfileContract
                .legacyV4RegistryRequirements
        )
        let freshByTarget = Dictionary(uniqueKeysWithValues:
            WindowsFontCompatibilityProfileContract.freshWineRegistryReplacements
                .map { ($0.target.descriptorID, $0) }
        )
        for replacement in
            WindowsFontCompatibilityProfileContract.legacyV4RegistryReplacements {
            try store.replaceFixtureValue(
                with: freshByTarget[replacement.target.descriptorID]?.baseline ??
                    replacement.target
            )
        }
        if let dialogReplacement = WindowsFontCompatibilityProfileContract
            .freshWineRegistryReplacements.first(where: {
                $0.target.valueName == "MS Shell Dlg"
            }) {
            try store.replaceFixtureValue(with: dialogReplacement.baseline)
        }
        let before = try store.serializedSystemRegistry()
        let profile = fontV13FreshWineBaselineProfile(
            definition: WindowsFontCompatibilityProfileContract.definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )

        do {
            _ = try await profile.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("a v4 marker must prevent fallback to the fresh-Wine family")
        } catch WindowsFontCompatibilityProfileError.collision(let reason) {
            XCTAssertTrue(reason.contains("legacy-v4-font-profile-evidence-mismatch"))
        }
        XCTAssertEqual(try store.serializedSystemRegistry(), before)
        XCTAssertTrue(profile.consumedOperations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))
    }

    func testWindowsFontLegacyV4PayloadModeDriftIsZeroWriteCollision() async throws {
        let fixture = try fontV13MakeLifecycleFixture("legacy-v4-payload-mode")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fontV13InstallExactLegacyV4Evidence(prefix: fixture.prefix)
        try fontV13InstallProductionPayloadSources(at: fixture.sourceRoot)
        let payload = try XCTUnwrap(
            WindowsFontCompatibilityProfileContract.fontPayloads.first(where: {
                $0.sourceRole == .runtimeNanum
            })
        )
        let installedPayload = fixture.prefix.appending(
            path: "drive_c/windows/Fonts/\(payload.fileName)"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o664],
            ofItemAtPath: installedPayload.path
        )
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: WindowsFontCompatibilityProfileContract
                .legacyV4RegistryRequirements
        )
        let before = try store.serializedSystemRegistry()
        let profile = fontV13FreshWineBaselineProfile(
            definition: WindowsFontCompatibilityProfileContract.definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )

        do {
            _ = try await profile.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("writable legacy payload evidence must not be adopted")
        } catch WindowsFontCompatibilityProfileError.collision(let reason) {
            XCTAssertTrue(reason.contains("legacy-v4-font-profile-evidence-mismatch"))
        }
        XCTAssertEqual(try store.serializedSystemRegistry(), before)
        XCTAssertTrue(profile.consumedOperations.isEmpty)
    }

    func testWindowsFontFreshWineBaselineApplyReplacesOnlyExactSupportedValues() async throws {
        let fixture = try fontV13MakeLifecycleFixture("fresh-baseline-apply")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let definition = fontV13FreshWineBaselineDefinition()
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: fontV13FreshWineBaselineEntries()
        )
        let profile = fontV13FreshWineBaselineProfile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )

        let applyResult = try await profile.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(applyResult)

        for replacement in
            WindowsFontCompatibilityProfileContract.freshWineRegistryReplacements {
            XCTAssertEqual(
                store.values(for: replacement.target),
                replacement.target.orderedValues
            )
        }
        for requirement in
            WindowsFontCompatibilityProfileContract.freshWineAlreadyTargetRequirements {
            XCTAssertEqual(store.values(for: requirement), requirement.orderedValues)
        }
        XCTAssertEqual(
            Set(store.writeAheadReplacementIDs),
            Set(WindowsFontCompatibilityProfileContract
                .freshWineRegistryReplacements.map(\.replacementID))
        )
        let marker = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fontV13MarkerURL(fixture.prefix))
            ) as? [String: Any]
        )
        XCTAssertEqual(marker["schemaVersion"] as? Int, 2)
        XCTAssertEqual(
            Set(try XCTUnwrap(marker["ownedRegistryIDs"] as? [String])),
            Set(WindowsFontCompatibilityProfileContract
                .freshWineRegistryReplacements.map(\.replacementID))
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))
    }

    func testWindowsFontPreviousFreshWineBaselineRemainsRestorable() async throws {
        let fixture = try fontV13MakeLifecycleFixture("previous-fresh-baseline")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let definition = fontV13FreshWineBaselineDefinition()
        let previous = WindowsFontCompatibilityProfileContract
            .previousFreshWineRegistryReplacements
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: previous.map(\.baseline) +
                WindowsFontCompatibilityProfileContract
                    .freshWineAlreadyTargetRequirements
        )
        let profile = fontV13FreshWineBaselineProfile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )

        _ = try await profile.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )

        for replacement in previous {
            XCTAssertEqual(
                store.values(for: replacement.target),
                replacement.target.orderedValues
            )
        }
        XCTAssertEqual(
            Set(store.writeAheadReplacementIDs),
            Set(previous.map(\.replacementID))
        )
        let marker = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fontV13MarkerURL(fixture.prefix))
            ) as? [String: Any]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(marker["ownedRegistryIDs"] as? [String])),
            Set(previous.map(\.replacementID))
        )
    }

    func testWindowsFontAppleHostRegistrationIsAdoptedWithoutOverwrite() async throws {
        let fixture = try fontV13MakeLifecycleFixture("apple-host-font-adoption")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let nanum = try XCTUnwrap(
            WindowsFontCompatibilityProfileContract.registryRequirements.first {
                $0.valueName == "NanumGothic (TrueType)"
            }
        )
        let hostRegistration = WindowsFontRegistryRequirement(
            registryPath: nanum.registryPath,
            valueName: nanum.valueName,
            valueType: nanum.valueType,
            orderedValues: [
                "Z:\\System\\Library\\AssetsV2\\" +
                    "com_apple_MobileAsset_Font8\\fixture.asset\\" +
                    "AssetData\\NanumGothic.ttc"
            ]
        )
        let freshTargets = WindowsFontCompatibilityProfileContract
            .freshWineRegistryReplacements.map(\.target)
        let anchors = WindowsFontCompatibilityProfileContract
            .freshWineAlreadyTargetRequirements
        let definition = fontV13Definition(
            registryRequirements: freshTargets + anchors + [nanum]
        )
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: WindowsFontCompatibilityProfileContract
                .freshWineRegistryReplacements.map(\.baseline) +
                anchors + [hostRegistration]
        )
        let profile = fontV13FreshWineBaselineProfile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )

        _ = try await profile.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )

        XCTAssertEqual(store.values(for: nanum), hostRegistration.orderedValues)
        XCTAssertFalse(profile.consumedOperations.contains(where: {
            $0.operationKind == .registrySet &&
                $0.resourceIDOrPathID == nanum.descriptorID
        }))
        let systemSnapshot = try WindowsFontRegistrySnapshotState.load(
            url: fixture.prefix.appending(path: "system.reg"),
            fileManager: .default
        )
        XCTAssertTrue(
            WindowsFontCompatibilityProfileContract
                .isSatisfiedRegistryRequirement(
                    snapshot: systemSnapshot,
                    requirement: nanum
                )
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fontV13MarkerURL(fixture.prefix).path
        ))
    }

    func testWindowsFontCommittedMarkerReconcilesKnownFiveEntryRegistryDrift() async throws {
        let fixture = try fontV13MakeLifecycleFixture("committed-five-entry-drift")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let current = WindowsFontCompatibilityProfileContract
            .freshWineRegistryReplacements
        let previous = WindowsFontCompatibilityProfileContract
            .previousFreshWineRegistryReplacements
        let anchors = WindowsFontCompatibilityProfileContract
            .freshWineAlreadyTargetRequirements
        let nanumRequirements = WindowsFontCompatibilityProfileContract
            .registryRequirements.filter {
                ["NanumGothic (TrueType)", "NanumGothic Bold (TrueType)"]
                    .contains($0.valueName)
            }.sorted { $0.descriptorID < $1.descriptorID }
        XCTAssertEqual(nanumRequirements.count, 2)
        let hostRegistrations = nanumRequirements.enumerated().map { index, requirement in
            WindowsFontRegistryRequirement(
                registryPath: requirement.registryPath,
                valueName: requirement.valueName,
                valueType: requirement.valueType,
                orderedValues: [
                    "Z:\\System\\Library\\AssetsV2\\" +
                        "com_apple_MobileAsset_Font8\\fixture\(index).asset\\" +
                        "AssetData\\NanumGothic.ttc"
                ]
            )
        }
        let definition = fontV13Definition(
            registryRequirements: current.map(\.target) + anchors + nanumRequirements
        )
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: current.map(\.baseline) + anchors + hostRegistrations
        )
        let profile = fontV13FreshWineBaselineProfile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )

        let initialApply = try await profile.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(initialApply)
        let originalMarker = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fontV13MarkerURL(fixture.prefix))
            ) as? [String: Any]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(originalMarker["ownedRegistryIDs"] as? [String])),
            Set(current.map(\.replacementID))
        )

        for replacement in previous {
            try store.replaceFixtureValue(with: replacement.baseline)
        }
        for requirement in nanumRequirements {
            try store.removeFixtureValue(for: requirement)
        }
        let priorWriteAheadCount = store.writeAheadReplacementIDs.count

        let reconciledApply = try await profile.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(reconciledApply)

        for replacement in current {
            XCTAssertEqual(
                store.values(for: replacement.target),
                replacement.target.orderedValues
            )
        }
        for requirement in nanumRequirements {
            XCTAssertEqual(store.values(for: requirement), requirement.orderedValues)
        }
        XCTAssertEqual(
            Set(store.writeAheadReplacementIDs.dropFirst(priorWriteAheadCount)),
            Set(previous.map(\.replacementID))
        )
        let reconciledMarker = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fontV13MarkerURL(fixture.prefix))
            ) as? [String: Any]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(reconciledMarker["ownedRegistryIDs"] as? [String])),
            Set(previous.map(\.replacementID))
                .union(nanumRequirements.map(\.descriptorID))
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))

        _ = try await profile.uninstall(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        for replacement in previous {
            XCTAssertEqual(
                store.values(for: replacement.baseline),
                replacement.baseline.orderedValues
            )
        }
        for requirement in nanumRequirements {
            XCTAssertNil(store.values(for: requirement))
        }
        for requirement in anchors {
            XCTAssertEqual(store.values(for: requirement), requirement.orderedValues)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13MarkerURL(fixture.prefix).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))
    }

    func testWindowsFontCommittedMarkerForeignDriftRemainsZeroWrite() async throws {
        let fixture = try fontV13MakeLifecycleFixture("committed-foreign-drift")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let definition = fontV13FreshWineBaselineDefinition()
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: fontV13FreshWineBaselineEntries()
        )
        let profile = fontV13FreshWineBaselineProfile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )
        let initialApply = try await profile.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(initialApply)
        let target = try XCTUnwrap(
            WindowsFontCompatibilityProfileContract
                .freshWineRegistryReplacements.first(where: {
                    $0.target.valueName == "Microsoft Sans Serif"
                })?.target
        )
        try store.replaceFixtureValue(with: WindowsFontRegistryRequirement(
            registryPath: target.registryPath,
            valueName: target.valueName,
            valueType: target.valueType,
            orderedValues: ["USERFONT.TTF,User Font"]
        ))
        let registryBefore = try store.serializedSystemRegistry()
        let markerBefore = try Data(contentsOf: fontV13MarkerURL(fixture.prefix))

        do {
            _ = try await profile.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("foreign post-commit font state must remain a zero-write conflict")
        } catch WindowsFontCompatibilityProfileError.collision(let reason) {
            XCTAssertTrue(reason.contains("owned-replacement-foreign-drift"), reason)
            XCTAssertTrue(reason.contains("observedDigest="), reason)
            XCTAssertTrue(reason.contains("expectedDigest="), reason)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(try store.serializedSystemRegistry(), registryBefore)
        XCTAssertEqual(
            try Data(contentsOf: fontV13MarkerURL(fixture.prefix)),
            markerBefore
        )
        XCTAssertTrue(profile.consumedOperations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))
    }

    func testWindowsFontCommittedReconciliationResumesAfterRegistryInterruption() async throws {
        let fixture = try fontV13MakeLifecycleFixture("committed-reconcile-resume")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let definition = fontV13FreshWineBaselineDefinition()
        let current = WindowsFontCompatibilityProfileContract
            .freshWineRegistryReplacements
        let previous = WindowsFontCompatibilityProfileContract
            .previousFreshWineRegistryReplacements
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: fontV13FreshWineBaselineEntries()
        )
        let profile = fontV13FreshWineBaselineProfile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )
        let initialApply = try await profile.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(initialApply)
        for replacement in previous {
            try store.replaceFixtureValue(with: replacement.baseline)
        }
        store.failAfterFirstReplacementTargetSet = true

        do {
            _ = try await profile.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("the fixture must interrupt committed reconciliation")
        } catch {
            XCTAssertEqual(
                error as? WindowsFontV13FixtureError,
                .injected(.registrySet, .processThrownError)
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))
        store.failAfterFirstReplacementTargetSet = false

        let resumedApply = try await profile.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(resumedApply)
        for replacement in current {
            XCTAssertEqual(
                store.values(for: replacement.target),
                replacement.target.orderedValues
            )
        }
        let marker = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fontV13MarkerURL(fixture.prefix))
            ) as? [String: Any]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(marker["ownedRegistryIDs"] as? [String])),
            Set(previous.map(\.replacementID))
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))
    }

    func testWindowsFontCommittedReconciliationResumesAfterMarkerDurabilityInterruption() async throws {
        let fixture = try fontV13MakeLifecycleFixture("committed-marker-resume")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let definition = fontV13FreshWineBaselineDefinition()
        let previous = WindowsFontCompatibilityProfileContract
            .previousFreshWineRegistryReplacements
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: fontV13FreshWineBaselineEntries()
        )
        let initialProfile = fontV13FreshWineBaselineProfile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )
        let initialApply = try await initialProfile.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(initialApply)
        for replacement in previous {
            try store.replaceFixtureValue(with: replacement.baseline)
        }
        let interruptedProfile = fontV13FreshWineBaselineProfile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            store: store,
            interruptAfter: .committedMarkerParentFSync
        )

        do {
            _ = try await interruptedProfile.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("marker durability interruption must retain recovery evidence")
        } catch WindowsFontCompatibilityProfileError.interruptedAfterOperation(_) {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))

        let recoveryProfile = fontV13FreshWineBaselineProfile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )
        let recovered = try await recoveryProfile.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(recovered)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))
        let marker = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fontV13MarkerURL(fixture.prefix))
            ) as? [String: Any]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(marker["ownedRegistryIDs"] as? [String])),
            Set(previous.map(\.replacementID))
        )
    }

    func testWindowsFontFreshWineBaselineForeignCollisionIsZeroWrite() async throws {
        let fixture = try fontV13MakeLifecycleFixture("fresh-baseline-foreign")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let definition = fontV13FreshWineBaselineDefinition()
        let entries = fontV13FreshWineBaselineEntries().map { requirement in
            guard requirement.valueName == "Microsoft Sans Serif" else {
                return requirement
            }
            return WindowsFontRegistryRequirement(
                registryPath: requirement.registryPath,
                valueName: requirement.valueName,
                valueType: requirement.valueType,
                orderedValues: ["USERFONT.TTF,User Font"]
            )
        }
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: entries
        )
        let before = try store.serializedSystemRegistry()
        let profile = fontV13FreshWineBaselineProfile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )

        do {
            _ = try await profile.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("foreign fresh-prefix font state must collide before mutation")
        } catch WindowsFontCompatibilityProfileError.collision(let reason) {
            XCTAssertTrue(reason.contains("classification=foreign-present"), reason)
            XCTAssertTrue(reason.contains("observedDigest="), reason)
            XCTAssertTrue(reason.contains("expectedDigest="), reason)
            XCTAssertFalse(reason.contains("NanumGothic-Regular.ttf ->"), reason)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(try store.serializedSystemRegistry(), before)
        XCTAssertTrue(profile.consumedOperations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13MarkerURL(fixture.prefix).path
        ))
    }

    func testWindowsFontFreshWineBaselinePostReplacementFailureRestoresBaseline() async throws {
        let fixture = try fontV13MakeLifecycleFixture("fresh-baseline-rollback")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let definition = fontV13FreshWineBaselineDefinition()
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: fontV13FreshWineBaselineEntries()
        )
        store.failAfterFirstReplacementTargetSet = true
        let profile = fontV13FreshWineBaselineProfile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )

        do {
            _ = try await profile.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("post-replacement failure must roll back the exact baseline")
        } catch {
            XCTAssertEqual(
                error as? WindowsFontV13FixtureError,
                .injected(.registrySet, .processThrownError)
            )
        }

        for replacement in
            WindowsFontCompatibilityProfileContract.freshWineRegistryReplacements {
            XCTAssertEqual(
                store.values(for: replacement.baseline),
                replacement.baseline.orderedValues
            )
        }
        for requirement in
            WindowsFontCompatibilityProfileContract.freshWineAlreadyTargetRequirements {
            XCTAssertEqual(store.values(for: requirement), requirement.orderedValues)
        }
        XCTAssertEqual(store.writeAheadReplacementIDs.count, 1)
        XCTAssertTrue(profile.consumedOperations.contains {
            $0.operationKind == .replacedRegistryRestore
        })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13MarkerURL(fixture.prefix).path
        ))
    }

    func testWindowsFontFreshWineBaselineUninstallRestoresBaseline() async throws {
        let fixture = try fontV13MakeLifecycleFixture("fresh-baseline-uninstall")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let definition = fontV13FreshWineBaselineDefinition()
        let store = try WindowsFontFreshBaselineRegistryStore(
            prefix: fixture.prefix,
            entries: fontV13FreshWineBaselineEntries()
        )
        let profile = fontV13FreshWineBaselineProfile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            store: store
        )

        let applyResult = try await profile.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(applyResult)
        let uninstallResult = try await profile.uninstall(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(uninstallResult)

        for replacement in
            WindowsFontCompatibilityProfileContract.freshWineRegistryReplacements {
            XCTAssertEqual(
                store.values(for: replacement.baseline),
                replacement.baseline.orderedValues
            )
        }
        for requirement in
            WindowsFontCompatibilityProfileContract.freshWineAlreadyTargetRequirements {
            XCTAssertEqual(store.values(for: requirement), requirement.orderedValues)
        }
        XCTAssertEqual(
            Set(profile.consumedOperations.filter {
                $0.operationKind == .replacedRegistryRestore
            }.map(\.resourceIDOrPathID)),
            Set(WindowsFontCompatibilityProfileContract
                .freshWineRegistryReplacements.map(\.replacementID))
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13JournalURL(fixture.prefix).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fontV13MarkerURL(fixture.prefix).path
        ))
    }

    func testWindowsFontV13LifecycleRegistryHasExactControllingOrderAndMemberships() throws {
        let expectedKinds: [WindowsFontLifecycleOperationKind] = [
            .journalExclusiveCreate,
            .journalCompleteWrite,
            .journalFileFSync,
            .journalClose,
            .journalReopenCanonicalVerify,
            .journalParentDirectoryFSync,
            .plannedDirectoryCreateVerify,
            .plannedDirectoryContainingParentFSync,
            .payloadStageExclusiveCreate,
            .payloadAuthenticatedSourceCopy,
            .payloadStageFSyncHashVerify,
            .committedOwnershipStageExclusiveCreate,
            .committedOwnershipStageCompleteWrite,
            .committedOwnershipStageFileFSync,
            .committedOwnershipStageClose,
            .committedOwnershipStageReopenCanonicalVerify,
            .committedOwnershipExchange,
            .committedOwnershipDriveCFSync,
            .committedOwnershipStaleStageUnlink,
            .committedOwnershipUpdateParentFSync,
            .committedOwnershipUpdateParentClose,
            .committedOwnershipCanonicalReread,
            .payloadNoOverwriteDestinationPublish,
            .payloadPublicationStageParentFSync,
            .payloadPublicationDestinationParentFSync,
            .registrySet,
            .forwardRegistryFlush,
            .markerFreeCompleteInspection,
            .markerStageExclusiveCreate,
            .markerCompleteWrite,
            .markerFileFSync,
            .markerReopenCanonicalVerify,
            .markerNoOverwritePublication,
            .markerPublicationStageParentFSync,
            .markerParentDirectoryFSync,
            .committedDirectoryContainingParentFSync,
            .committedPayloadStageParentFSync,
            .committedPayloadDestinationParentFSync,
            .committedMarkerStageParentFSync,
            .committedMarkerParentFSync,
            .ownedRegistryDelete,
            .replacedRegistryRestore,
            .compensationRegistryFlush,
            .ownedFileDelete,
            .ownedFileDeletionParentFSync,
            .boundStageDelete,
            .plannedDirectoryDelete,
            .plannedDirectoryDeletionContainingParentFSync,
            .adoptedStateVerification,
            .markerDelete,
            .markerDeletionParentDirectoryFSync,
            .journalDelete,
            .journalDeletionParentDirectoryFSync
        ]
        let specifications = WindowsFontLifecycleOperationRegistry.specifications

        XCTAssertEqual(specifications.count, 53)
        XCTAssertEqual(specifications.map(\.operationKind), expectedKinds)
        XCTAssertEqual(Set(specifications.map(\.operationKind)).count, 53)
        XCTAssertEqual(Set(expectedKinds), Set(WindowsFontLifecycleOperationKind.allCases))
        XCTAssertEqual(WindowsFontLifecycleOperationRegistry.failureKindMembershipCount, 92)
        XCTAssertEqual(
            Set(specifications.flatMap(\.failureKinds)),
            Set(WindowsFontLifecycleFailureKind.allCases)
        )
        XCTAssertEqual(WindowsFontLifecycleFailureKind.allCases.count, 8)
        XCTAssertTrue(specifications.allSatisfy { !$0.phase.isEmpty })
        XCTAssertTrue(specifications.allSatisfy { !$0.resourceDomain.isEmpty })
        XCTAssertTrue(specifications.allSatisfy { !$0.failureKinds.isEmpty })
        XCTAssertTrue(specifications.allSatisfy {
            Set($0.failureKinds).count == $0.failureKinds.count
        })
    }

    func testWindowsFontV13ProductionSizedProjectionHasExactInstancesFailuresAndInterruptions() throws {
        let resources = fontV13ProductionSizedResources()
        let projection = try WindowsFontLifecycleOperationProjection.make(
            resourcesByOperationKind: resources
        )

        XCTAssertEqual(Set(resources.keys), Set(WindowsFontLifecycleOperationKind.allCases))
        try projection.validateExactEquality(resourcesByOperationKind: resources)
        XCTAssertEqual(Set(projection.operationInstances.map(\.operationID)).count,
                       projection.operationInstances.count)
        XCTAssertEqual(projection.interruptionCases.count, projection.operationInstances.count)
        XCTAssertTrue(projection.interruptionCases.allSatisfy(\.interruptAfterSuccessfulOperation))

        for specification in WindowsFontLifecycleOperationRegistry.specifications {
            let expectedResources = resources[specification.operationKind] ?? []
            let instances = projection.operationInstances.filter {
                $0.operationKind == specification.operationKind
            }
            XCTAssertEqual(instances.map(\.resourceIDOrPathID), expectedResources)
            XCTAssertEqual(instances.map(\.ordinal), Array(expectedResources.indices))
            for instance in instances {
                XCTAssertEqual(
                    projection.failureCases.filter {
                        $0.operationID == instance.operationID
                    }.map(\.failureKind),
                    specification.failureKinds
                )
                XCTAssertEqual(
                    projection.interruptionCases.filter {
                        $0.operationID == instance.operationID
                    },
                    [WindowsFontLifecycleInterruptionCase(
                        operationID: instance.operationID,
                        interruptAfterSuccessfulOperation: true
                    )]
                )
            }
        }
        try projection.validateExactConsumption(projection.operationInstances)
    }

    func testWindowsFontV13ProjectionRejectsAllSevenPlannerNegativeFamilies() throws {
        let resources = fontV13ProductionSizedResources()
        let exact = try WindowsFontLifecycleOperationProjection.make(
            resourcesByOperationKind: resources
        )

        var missingInstance = exact
        missingInstance.operationInstances.removeFirst()
        XCTAssertThrowsError(
            try missingInstance.validateExactEquality(resourcesByOperationKind: resources)
        )

        var addedInstance = exact
        addedInstance.operationInstances.append(try WindowsFontLifecycleOperationRegistry.instance(
            operationKind: .journalExclusiveCreate,
            resourceIDOrPathID: "unapproved-added-instance",
            ordinal: 1
        ))
        XCTAssertThrowsError(
            try addedInstance.validateExactEquality(resourcesByOperationKind: resources)
        )

        var reorderedInstances = exact
        reorderedInstances.operationInstances.swapAt(0, 1)
        XCTAssertThrowsError(
            try reorderedInstances.validateExactEquality(resourcesByOperationKind: resources)
        )

        var missingFailure = exact
        missingFailure.failureCases.removeFirst()
        XCTAssertThrowsError(
            try missingFailure.validateExactEquality(resourcesByOperationKind: resources)
        )

        var addedInapplicableFailure = exact
        addedInapplicableFailure.failureCases.append(WindowsFontLifecycleFailureCase(
            operationID: exact.operationInstances[0].operationID,
            failureKind: .processThrownError
        ))
        XCTAssertThrowsError(
            try addedInapplicableFailure.validateExactEquality(resourcesByOperationKind: resources)
        )

        var missingInterruption = exact
        missingInterruption.interruptionCases.removeFirst()
        XCTAssertThrowsError(
            try missingInterruption.validateExactEquality(resourcesByOperationKind: resources)
        )
        var duplicatedInterruption = exact
        duplicatedInterruption.interruptionCases.append(exact.interruptionCases[0])
        XCTAssertThrowsError(
            try duplicatedInterruption.validateExactEquality(resourcesByOperationKind: resources)
        )

        XCTAssertThrowsError(
            try exact.validateExactConsumption(Array(exact.operationInstances.dropLast()))
        )
    }

    func testWindowsFontV13EveryProjectedInstanceUsesOnlyItsApplicableFailureSeam() async throws {
        let projection = try WindowsFontLifecycleOperationProjection.make(
            resourcesByOperationKind: fontV13ProductionSizedResources()
        )
        let runtime = URL(fileURLWithPath: "/forgeplay-fixture/wine")
        let prefix = URL(fileURLWithPath: "/forgeplay-fixture/prefix")
        let logs = URL(fileURLWithPath: "/forgeplay-fixture/logs")
        let runnerAction = RunnerAction.waitForWinePrefix(
            runtimeExecutable: runtime,
            prefix: prefix,
            logDirectory: logs
        )

        for failureCase in projection.failureCases {
            let instance = try XCTUnwrap(projection.operationInstances.first {
                $0.operationID == failureCase.operationID
            })
            let hooks = WindowsFontLifecycleExecutionHooks(
                filesystemOperationExecutor: { operation, _ in
                    throw WindowsFontV13FixtureError.injected(
                        operation.operationKind,
                        failureCase.failureKind
                    )
                },
                runnerActionExecutor: { operation, _ in
                    if failureCase.failureKind == .processUnsuccessfulResult {
                        return self.fontV13ProcessResult(exitCode: 1)
                    }
                    throw WindowsFontV13FixtureError.injected(
                        operation.operationKind,
                        failureCase.failureKind
                    )
                },
                completionObserver: { _ in }
            )

            if [.processUnsuccessfulResult, .processThrownError]
                .contains(failureCase.failureKind) {
                do {
                    let result = try await hooks.runnerActionExecutor(instance, runnerAction)
                    XCTAssertEqual(failureCase.failureKind, .processUnsuccessfulResult)
                    XCTAssertFalse(result.succeeded)
                } catch {
                    XCTAssertEqual(failureCase.failureKind, .processThrownError)
                    XCTAssertEqual(
                        error as? WindowsFontV13FixtureError,
                        .injected(instance.operationKind, failureCase.failureKind)
                    )
                }
            } else {
                XCTAssertThrowsError(
                    try hooks.filesystemOperationExecutor(instance, {})
                ) { error in
                    XCTAssertEqual(
                        error as? WindowsFontV13FixtureError,
                        .injected(instance.operationKind, failureCase.failureKind)
                    )
                }
            }
        }

        for interruption in projection.interruptionCases {
            let instance = try XCTUnwrap(projection.operationInstances.first {
                $0.operationID == interruption.operationID
            })
            let hooks = WindowsFontLifecycleExecutionHooks(
                filesystemOperationExecutor: { _, body in try body() },
                runnerActionExecutor: { _, _ in self.fontV13ProcessResult(exitCode: 0) },
                completionObserver: { completed in
                    guard completed.operationID != interruption.operationID else {
                        throw WindowsFontCompatibilityProfileError.interruptedAfterOperation(
                            completed.operationID
                        )
                    }
                }
            )
            XCTAssertThrowsError(try hooks.completionObserver(instance)) { error in
                XCTAssertEqual(
                    error as? WindowsFontCompatibilityProfileError,
                    .interruptedAfterOperation(instance.operationID)
                )
            }
        }
    }

    func testWindowsFontV13DescriptorsHaveExactSourcesNamesAndNonSelfReferentialCascades() {
        let payloads = WindowsFontCompatibilityProfileContract.fontPayloads
        let requirements = WindowsFontCompatibilityProfileContract.registryRequirements
        let notoDisplayNames = payloads
            .filter { $0.sourceRole == .appNotoPack }
            .map(\.registryDisplayName)

        XCTAssertEqual(payloads.count, 12)
        XCTAssertEqual(Set(payloads.map(\.descriptorID)).count, 12)
        XCTAssertEqual(Set(payloads.map(\.fileName)).count, 12)
        XCTAssertEqual(payloads.filter { $0.sourceRole == .runtimeNanum }.count, 2)
        XCTAssertEqual(payloads.filter { $0.sourceRole == .appNotoPack }.count, 10)
        XCTAssertEqual(notoDisplayNames, [
            "Noto Sans (TrueType)",
            "Noto Sans Bold (TrueType)",
            "Noto Sans CJK KR (OpenType)",
            "Noto Sans CJK KR Bold (OpenType)",
            "Noto Sans CJK JP (OpenType)",
            "Noto Sans CJK JP Bold (OpenType)",
            "Noto Sans CJK SC (OpenType)",
            "Noto Sans CJK SC Bold (OpenType)",
            "Noto Sans CJK TC (OpenType)",
            "Noto Sans CJK TC Bold (OpenType)"
        ])
        XCTAssertEqual(requirements.count, 32)
        XCTAssertEqual(Set(requirements.map(\.descriptorID)).count, 32)

        let freshWineSystemLinkPath =
            "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink"
        let freshWineSubstitutesPath =
            "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes"
        let freshWineSystemLinkValues = [
            "MSGOTHIC.TTC,MS UI Gothic",
            "MINGLIU.TTC,PMingLiU",
            "SIMSUN.TTC,SimSun",
            "GULIM.TTC,Gulim",
            "YUGOTHM.TTC,Yu Gothic UI",
            "MSJH.TTC,Microsoft JhengHei UI",
            "MSYH.TTC,Microsoft YaHei UI",
            "MALGUN.TTF,Malgun Gothic",
            "SEGUISYM.TTF,Segoe UI Symbol"
        ]
        let expectedFreshWineBaselines = [
            WindowsFontRegistryRequirement(
                registryPath: freshWineSystemLinkPath,
                valueName: "Microsoft Sans Serif",
                valueType: "REG_MULTI_SZ",
                orderedValues: freshWineSystemLinkValues
            ),
            WindowsFontRegistryRequirement(
                registryPath: freshWineSystemLinkPath,
                valueName: "Tahoma",
                valueType: "REG_MULTI_SZ",
                orderedValues: freshWineSystemLinkValues
            ),
            WindowsFontRegistryRequirement(
                registryPath: freshWineSubstitutesPath,
                valueName: "MS Shell Dlg",
                valueType: "REG_SZ",
                orderedValues: ["Tahoma"]
            )
        ]
        let freshWineReplacements =
            WindowsFontCompatibilityProfileContract.freshWineRegistryReplacements
        XCTAssertEqual(freshWineReplacements.count, 3)
        XCTAssertEqual(Set(freshWineReplacements.map(\.replacementID)).count, 3)
        XCTAssertEqual(
            WindowsFontCompatibilityProfileContract
                .previousFreshWineRegistryReplacements.count,
            3
        )
        XCTAssertTrue(
            Set(freshWineReplacements.map(\.replacementID)).isDisjoint(with:
                Set(WindowsFontCompatibilityProfileContract
                    .previousFreshWineRegistryReplacements.map(\.replacementID))
            )
        )
        for expectedBaseline in expectedFreshWineBaselines {
            let matchingReplacements = freshWineReplacements.filter {
                $0.baseline.registryPath == expectedBaseline.registryPath &&
                    $0.baseline.valueName == expectedBaseline.valueName
            }
            XCTAssertEqual(matchingReplacements.count, 1)
            guard let replacement = matchingReplacements.first else {
                continue
            }
            XCTAssertEqual(replacement.baseline, expectedBaseline)
            XCTAssertEqual(
                requirements.filter {
                    $0.registryPath == expectedBaseline.registryPath &&
                        $0.valueName == expectedBaseline.valueName
                },
                [replacement.target]
            )
        }

        let expectedFreshWineAnchor = WindowsFontRegistryRequirement(
            registryPath: freshWineSubstitutesPath,
            valueName: "MS Shell Dlg 2",
            valueType: "REG_SZ",
            orderedValues: ["Tahoma"]
        )
        XCTAssertEqual(
            WindowsFontCompatibilityProfileContract.freshWineAlreadyTargetRequirements,
            [expectedFreshWineAnchor]
        )
        XCTAssertEqual(
            requirements.filter {
                $0.registryPath == expectedFreshWineAnchor.registryPath &&
                    $0.valueName == expectedFreshWineAnchor.valueName
            },
            [expectedFreshWineAnchor]
        )

        let links = requirements.filter { $0.valueType == "REG_MULTI_SZ" }
        XCTAssertEqual(links.count, 7)
        for family in WindowsFontCompatibilityProfileContract.linkedLatinFamilies {
            XCTAssertEqual(
                links.first(where: { $0.valueName == family })?.orderedValues,
                WindowsFontCompatibilityProfileContract.linkedLatinFallbackFiles
            )
        }
        XCTAssertEqual(
            links.first(where: { $0.valueName == "NanumGothic" })?.orderedValues,
            WindowsFontCompatibilityProfileContract.nanumFallbackFiles
        )
        XCTAssertEqual(
            links.first(where: { $0.valueName == "Noto Sans" })?.orderedValues,
            WindowsFontCompatibilityProfileContract.notoSansFallbackFiles
        )
        XCTAssertFalse(WindowsFontCompatibilityProfileContract.nanumFallbackFiles.contains(
            "NanumGothic-Regular.ttf"
        ))
        XCTAssertFalse(WindowsFontCompatibilityProfileContract.notoSansFallbackFiles.contains(
            "NotoSans-Regular.ttf"
        ))
    }

    func testWindowsFontV13RegistrySnapshotRequiresExactMultiStringOrderAndNoDuplicate() throws {
        let root = try fontV13ResetFixtureRoot("registry-snapshot")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = root.appending(path: "system.reg")
        let requirement = WindowsFontRegistryRequirement(
            registryPath: "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink",
            valueName: "Tahoma",
            valueType: "REG_MULTI_SZ",
            orderedValues: ["Nanum.ttf", "Noto.ttf", "CJK.otf"]
        )

        func values(_ lines: [String]) throws -> [String]? {
            let contents = ([
                "WINE REGISTRY Version 2",
                "",
                "[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\FontLink\\\\SystemLink]"
            ] + lines).joined(separator: "\n") + "\n"
            try Data(contents.utf8).write(to: registry)
            return try WindowsFontRegistrySnapshotState.load(
                url: registry,
                fileManager: .default
            ).orderedValues(for: requirement)
        }

        XCTAssertEqual(
            try values([#""Tahoma"=str(7):"Nanum.ttf\0Noto.ttf\0CJK.otf\0""#]),
            requirement.orderedValues
        )
        XCTAssertNotEqual(
            try values([#""Tahoma"=str(7):"Noto.ttf\0Nanum.ttf\0CJK.otf\0""#]),
            requirement.orderedValues
        )
        XCTAssertNotEqual(
            try values([#""Tahoma"=str(7):"Nanum.ttf\0Noto.ttf\0CJK.otf\0Extra.otf\0""#]),
            requirement.orderedValues
        )
        XCTAssertNil(try values([]))
        XCTAssertNil(try values([
            #""Tahoma"=str(7):"Nanum.ttf\0Noto.ttf\0CJK.otf\0""#,
            #""Tahoma"=str(7):"Nanum.ttf\0Noto.ttf\0CJK.otf\0""#
        ]))
    }

    func testWindowsFontV13JournalParentFailureStopsBeforeAllLaterMutation() async throws {
        let fixture = try fontV13MakeLifecycleFixture("journal-parent-failure")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profile = fontV13Profile(
            definition: fontV13Definition(),
            sourceRoot: fixture.sourceRoot,
            blockedOperation: .journalParentDirectoryFSync
        )

        do {
            _ = try await profile.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("journal parent fsync failure must fail closed")
        } catch let error as WindowsFontCompatibilityProfileError {
            guard case .journalDurabilityFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fontV13JournalURL(fixture.prefix).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fixture.prefix.appending(path: "drive_c/ForgePlay").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fixture.prefix.appending(path: "drive_c/windows/Fonts").path))
        XCTAssertEqual(profile.consumedOperations.last?.operationKind,
                       .journalParentDirectoryFSync)
        XCTAssertFalse(profile.consumedOperations.contains(where: {
            $0.operationKind == .plannedDirectoryCreateVerify
        }))
    }

    func testWindowsFontV13JournalParentInterruptionStopsBeforeAllLaterMutation() async throws {
        let fixture = try fontV13MakeLifecycleFixture("journal-parent-interruption")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profile = fontV13Profile(
            definition: fontV13Definition(),
            sourceRoot: fixture.sourceRoot,
            interruptAfter: .journalParentDirectoryFSync
        )

        do {
            _ = try await profile.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("interruption after journal-parent durability must stop the call")
        } catch let error as WindowsFontCompatibilityProfileError {
            guard case .interruptedAfterOperation = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fontV13JournalURL(fixture.prefix).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fixture.prefix.appending(path: "drive_c/ForgePlay").path))
        XCTAssertFalse(profile.consumedOperations.contains(where: {
            $0.operationKind == .plannedDirectoryCreateVerify
        }))
    }

    func testWindowsFontV13MarkerParentFailureRetainsMarkerAndJournalForRepair() async throws {
        let fixture = try fontV13MakeLifecycleFixture("marker-parent-repair")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let definition = fontV13Definition()
        let profile = fontV13Profile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            blockedOperation: .markerParentDirectoryFSync
        )

        do {
            _ = try await profile.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("marker parent fsync failure must retain recovery authority")
        } catch let error as WindowsFontCompatibilityProfileError {
            guard case .commitCleanupDurabilityUnknown = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fontV13MarkerURL(fixture.prefix).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fontV13JournalURL(fixture.prefix).path))

        let repair = fontV13Profile(definition: definition, sourceRoot: fixture.sourceRoot)
        let result = try await repair.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fontV13MarkerURL(fixture.prefix).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fontV13JournalURL(fixture.prefix).path))
    }

    func testWindowsFontV13JournalDeletionParentFailureDoesNotRecreateJournal() async throws {
        let fixture = try fontV13MakeLifecycleFixture("journal-delete-parent")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let definition = fontV13Definition()
        let profile = fontV13Profile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            blockedOperation: .journalDeletionParentDirectoryFSync
        )

        do {
            _ = try await profile.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("journal deletion parent fsync failure must be visible")
        } catch let error as WindowsFontCompatibilityProfileError {
            guard case .cleanupDurabilityUnknown = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fontV13MarkerURL(fixture.prefix).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fontV13JournalURL(fixture.prefix).path))

        let idempotent = fontV13Profile(definition: definition, sourceRoot: fixture.sourceRoot)
        let result = try await idempotent.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(result)
        XCTAssertTrue(idempotent.consumedOperations.isEmpty)
    }

    func testWindowsFontV13CommittedNamespaceGateRetainsJournalUntilPayloadParentsSync() async throws {
        let fixture = try fontV13MakeLifecycleFixture("committed-namespace-gate")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let payloadData = Data("namespace-durability".utf8)
        let definition = fontV13Definition(payloads: [
            ("Durable.ttf", payloadData, .runtimeNanum)
        ])
        try fontV13WritePayloadSources(
            definition,
            dataByName: ["Durable.ttf": payloadData],
            sourceRoot: fixture.sourceRoot
        )
        let blocked = fontV13Profile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            blockedOperation: .committedPayloadDestinationParentFSync
        )

        do {
            _ = try await blocked.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("committed namespace gate failure must retain recovery authority")
        } catch let error as WindowsFontCompatibilityProfileError {
            guard case .commitCleanupDurabilityUnknown = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            fontV13MarkerURL(fixture.prefix).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            fontV13JournalURL(fixture.prefix).path
        ))
        XCTAssertFalse(blocked.consumedOperations.contains(where: {
            $0.operationKind == .journalDelete
        }))

        let repair = fontV13Profile(
            definition: definition,
            sourceRoot: fixture.sourceRoot
        )
        let repairResult = try await repair.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(repairResult)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fontV13JournalURL(fixture.prefix).path
        ))
        XCTAssertEqual(
            try Data(contentsOf: fixture.prefix.appending(
                path: "drive_c/windows/Fonts/Durable.ttf"
            )),
            payloadData
        )
    }

    func testWindowsFontV13MarkerDeletionParentFailureRetainsUninstallJournalForRepair() async throws {
        let fixture = try fontV13MakeLifecycleFixture("marker-delete-parent")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let definition = fontV13Definition()
        let applyProfile = fontV13Profile(
            definition: definition,
            sourceRoot: fixture.sourceRoot
        )
        let applyResult = try await applyProfile.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(applyResult)

        let uninstallProfile = fontV13Profile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            blockedOperation: .markerDeletionParentDirectoryFSync
        )
        do {
            _ = try await uninstallProfile.uninstall(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("marker deletion parent fsync failure must retain the uninstall journal")
        } catch let error as WindowsFontCompatibilityProfileError {
            guard case .uninstallDurabilityUnknown = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fontV13MarkerURL(fixture.prefix).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fontV13JournalURL(fixture.prefix).path))
        let kinds = uninstallProfile.consumedOperations.map(\.operationKind)
        XCTAssertTrue(kinds.contains(.markerDelete))
        XCTAssertEqual(kinds.last, .markerDeletionParentDirectoryFSync)
        XCTAssertFalse(kinds.contains(.journalDelete))

        let repairProfile = fontV13Profile(
            definition: definition,
            sourceRoot: fixture.sourceRoot
        )
        let repairResult = try await repairProfile.uninstall(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(repairResult)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fontV13MarkerURL(fixture.prefix).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fontV13JournalURL(fixture.prefix).path))
    }

    func testWindowsFontV13ApplyAndUninstallPreserveAdoptedPayloadAndRemoveOwnedPayload() async throws {
        let fixture = try fontV13MakeLifecycleFixture("owned-adopted")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adoptedData = Data("adopted-font-v1".utf8)
        let ownedData = Data("owned-font-v1".utf8)
        let secondOwnedData = Data("owned-font-v2".utf8)
        let definition = fontV13Definition(payloads: [
            ("FixtureAdopted.ttf", adoptedData, .runtimeNanum),
            ("FixtureOwned.otf", ownedData, .appNotoPack),
            ("FixtureOwnedTwo.ttf", secondOwnedData, .runtimeNanum)
        ])
        try fontV13WritePayloadSources(definition, dataByName: [
            "FixtureAdopted.ttf": adoptedData,
            "FixtureOwned.otf": ownedData,
            "FixtureOwnedTwo.ttf": secondOwnedData
        ], sourceRoot: fixture.sourceRoot)
        let fonts = fixture.prefix.appending(path: "drive_c/windows/Fonts")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try adoptedData.write(to: fonts.appending(path: "FixtureAdopted.ttf"))
        let profile = fontV13Profile(definition: definition, sourceRoot: fixture.sourceRoot)

        let applyResult = try await profile.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(applyResult)
        XCTAssertEqual(try Data(contentsOf: fonts.appending(path: "FixtureAdopted.ttf")), adoptedData)
        XCTAssertEqual(try Data(contentsOf: fonts.appending(path: "FixtureOwned.otf")), ownedData)
        XCTAssertEqual(
            try Data(contentsOf: fonts.appending(path: "FixtureOwnedTwo.ttf")),
            secondOwnedData
        )
        let payloadOperationKinds = profile.consumedOperations.map(\.operationKind).filter {
            [
                .payloadStageExclusiveCreate,
                .payloadAuthenticatedSourceCopy,
                .payloadStageFSyncHashVerify,
                .payloadNoOverwriteDestinationPublish
            ].contains($0)
        }
        XCTAssertEqual(payloadOperationKinds, [
            .payloadStageExclusiveCreate,
            .payloadStageExclusiveCreate,
            .payloadAuthenticatedSourceCopy,
            .payloadAuthenticatedSourceCopy,
            .payloadStageFSyncHashVerify,
            .payloadStageFSyncHashVerify,
            .payloadNoOverwriteDestinationPublish,
            .payloadNoOverwriteDestinationPublish
        ])

        let uninstallResult = try await profile.uninstall(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(uninstallResult)
        XCTAssertEqual(try Data(contentsOf: fonts.appending(path: "FixtureAdopted.ttf")), adoptedData)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fonts.appending(path: "FixtureOwned.otf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fonts.appending(path: "FixtureOwnedTwo.ttf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fontV13MarkerURL(fixture.prefix).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fontV13JournalURL(fixture.prefix).path))
    }

    func testWindowsFontV13CollisionPreflightCreatesNoJournal() async throws {
        let fixture = try fontV13MakeLifecycleFixture("collision")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let expected = Data("expected-font".utf8)
        let definition = fontV13Definition(payloads: [
            ("Fixture.ttf", expected, .runtimeNanum)
        ])
        try fontV13WritePayloadSources(
            definition,
            dataByName: ["Fixture.ttf": expected],
            sourceRoot: fixture.sourceRoot
        )
        let fonts = fixture.prefix.appending(path: "drive_c/windows/Fonts")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try Data("different-user-owned-font".utf8).write(to: fonts.appending(path: "Fixture.ttf"))
        let profile = fontV13Profile(definition: definition, sourceRoot: fixture.sourceRoot)

        do {
            _ = try await profile.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("a mismatched pre-existing destination must collide")
        } catch let error as WindowsFontCompatibilityProfileError {
            guard case .collision = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fontV13JournalURL(fixture.prefix).path))
        XCTAssertTrue(profile.consumedOperations.isEmpty)
    }

    func testWindowsFontV13InterruptionRepairsRollbackAndCommittedCleanup() async throws {
        let payloadFixture = try fontV13MakeLifecycleFixture("payload-interruption")
        defer { try? FileManager.default.removeItem(at: payloadFixture.root) }
        let payloadData = Data("interrupted-payload".utf8)
        let payloadDefinition = fontV13Definition(payloads: [
            ("Interrupted.ttf", payloadData, .runtimeNanum)
        ])
        try fontV13WritePayloadSources(
            payloadDefinition,
            dataByName: ["Interrupted.ttf": payloadData],
            sourceRoot: payloadFixture.sourceRoot
        )
        let interruptedPayloadProfile = fontV13Profile(
            definition: payloadDefinition,
            sourceRoot: payloadFixture.sourceRoot,
            interruptAfter: .committedOwnershipCanonicalReread
        )
        do {
            _ = try await interruptedPayloadProfile.apply(
                runtimeExecutable: payloadFixture.runtime,
                prefix: payloadFixture.prefix,
                logDirectory: payloadFixture.logs
            )
            XCTFail("durable payload ownership interruption must precede publication")
        } catch let error as WindowsFontCompatibilityProfileError {
            guard case .interruptedAfterOperation = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fontV13JournalURL(payloadFixture.prefix).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fontV13MarkerURL(payloadFixture.prefix).path))
        XCTAssertEqual(
            try fontV13CommittedOwnership(
                key: "committedOwnedFileIDs",
                prefix: payloadFixture.prefix
            ),
            [try XCTUnwrap(payloadDefinition.payloads.first?.descriptorID)]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: payloadFixture.prefix.appending(
                    path: "drive_c/windows/Fonts/Interrupted.ttf"
                ).path
            )
        )
        XCTAssertFalse(interruptedPayloadProfile.consumedOperations.contains(where: {
            $0.operationKind == .payloadNoOverwriteDestinationPublish
        }))

        let payloadRepair = fontV13Profile(
            definition: payloadDefinition,
            sourceRoot: payloadFixture.sourceRoot
        )
        let payloadRepairResult = try await payloadRepair.apply(
            runtimeExecutable: payloadFixture.runtime,
            prefix: payloadFixture.prefix,
            logDirectory: payloadFixture.logs
        )
        XCTAssertNil(payloadRepairResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fontV13MarkerURL(payloadFixture.prefix).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fontV13JournalURL(payloadFixture.prefix).path))

        let markerFixture = try fontV13MakeLifecycleFixture("marker-interruption")
        defer { try? FileManager.default.removeItem(at: markerFixture.root) }
        let emptyDefinition = fontV13Definition()
        let interruptedMarkerProfile = fontV13Profile(
            definition: emptyDefinition,
            sourceRoot: markerFixture.sourceRoot,
            interruptAfter: .markerNoOverwritePublication
        )
        do {
            _ = try await interruptedMarkerProfile.apply(
                runtimeExecutable: markerFixture.runtime,
                prefix: markerFixture.prefix,
                logDirectory: markerFixture.logs
            )
            XCTFail("marker publication interruption must retain both authorities")
        } catch let error as WindowsFontCompatibilityProfileError {
            guard case .interruptedAfterOperation = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fontV13MarkerURL(markerFixture.prefix).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fontV13JournalURL(markerFixture.prefix).path))

        let markerRepair = fontV13Profile(
            definition: emptyDefinition,
            sourceRoot: markerFixture.sourceRoot
        )
        let markerRepairResult = try await markerRepair.apply(
            runtimeExecutable: markerFixture.runtime,
            prefix: markerFixture.prefix,
            logDirectory: markerFixture.logs
        )
        XCTAssertNil(markerRepairResult)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fontV13JournalURL(markerFixture.prefix).path))
    }

    func testWindowsFontV13RegistryOwnershipInterruptionPrecedesRunnerAndRepairs() async throws {
        let fixture = try fontV13MakeLifecycleFixture("registry-interruption")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let requirement = WindowsFontRegistryRequirement(
            registryPath: "HKCU\\Software\\Wine\\Fonts\\ForcedReplacements",
            valueName: "Tahoma",
            valueType: "REG_SZ",
            orderedValues: ["ForgePlayFixture"]
        )
        let definition = fontV13Definition(
            registryRequirements: [requirement]
        )
        let userRegistry = fixture.prefix.appending(path: "user.reg")
        let registrySection = "Software\\\\Wine\\\\Fonts\\\\ForcedReplacements"
        let runnerActionExecutor: WindowsFontLifecycleExecutionHooks.RunnerActionExecutor = {
            _, action in
            switch action {
            case .setRegistryValue(
                _, let prefix, let path, let name, let type, let value, _, _
            ):
                XCTAssertEqual(prefix.standardizedFileURL, fixture.prefix.standardizedFileURL)
                XCTAssertEqual(path, requirement.registryPath)
                XCTAssertEqual(name, requirement.valueName)
                XCTAssertEqual(type, requirement.valueType)
                XCTAssertEqual(value, requirement.encodedRunnerValue)
                let contents = """
                WINE REGISTRY Version 2

                [\(registrySection)]
                "\(requirement.valueName)"="\(requirement.encodedRunnerValue)"
                """ + "\n"
                try contents.write(
                    to: userRegistry,
                    atomically: true,
                    encoding: .utf8
                )
            case .deleteRegistryValueIfPresent(
                _, let prefix, let path, let name, _
            ):
                XCTAssertEqual(prefix.standardizedFileURL, fixture.prefix.standardizedFileURL)
                XCTAssertEqual(path, requirement.registryPath)
                XCTAssertEqual(name, requirement.valueName)
                try "WINE REGISTRY Version 2\n".write(
                    to: userRegistry,
                    atomically: true,
                    encoding: .utf8
                )
            case .waitForWinePrefix:
                break
            default:
                XCTFail("unexpected registry lifecycle action: \(action)")
            }
            return self.fontV13ProcessResult(exitCode: 0)
        }
        let interrupted = fontV13Profile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            interruptAfter: .committedOwnershipCanonicalReread,
            runnerActionExecutor: runnerActionExecutor
        )

        do {
            _ = try await interrupted.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTFail("durable registry ownership interruption must precede runner mutation")
        } catch let error as WindowsFontCompatibilityProfileError {
            guard case .interruptedAfterOperation = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            try fontV13CommittedOwnership(
                key: "committedOwnedRegistryIDs",
                prefix: fixture.prefix
            ),
            [requirement.descriptorID]
        )
        XCTAssertNil(
            try WindowsFontRegistrySnapshotState.load(
                url: userRegistry,
                fileManager: .default
            ).orderedValues(for: requirement)
        )
        XCTAssertFalse(interrupted.consumedOperations.contains(where: {
            $0.operationKind == .registrySet
        }))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fontV13MarkerURL(fixture.prefix).path
            )
        )

        let repair = fontV13Profile(
            definition: definition,
            sourceRoot: fixture.sourceRoot,
            runnerActionExecutor: runnerActionExecutor
        )
        let repairResult = try await repair.apply(
            runtimeExecutable: fixture.runtime,
            prefix: fixture.prefix,
            logDirectory: fixture.logs
        )
        XCTAssertNil(repairResult)
        XCTAssertEqual(
            try WindowsFontRegistrySnapshotState.load(
                url: userRegistry,
                fileManager: .default
            ).orderedValues(for: requirement),
            requirement.orderedValues
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fontV13MarkerURL(fixture.prefix).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fontV13JournalURL(fixture.prefix).path
            )
        )
    }

    func testWindowsFontV13OwnershipExchangeAndStaleStageFailuresRecoverBeforeMutation() async throws {
        let cases: [(
            name: String,
            blocked: WindowsFontLifecycleOperationKind?,
            interrupted: WindowsFontLifecycleOperationKind?,
            expectsInterruption: Bool
        )] = [
            (
                "ownership-exchange-interruption",
                nil,
                .committedOwnershipExchange,
                true
            ),
            (
                "ownership-stale-stage-failure",
                .committedOwnershipStaleStageUnlink,
                nil,
                false
            )
        ]
        for testCase in cases {
            let fixture = try fontV13MakeLifecycleFixture(testCase.name)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let payloadData = Data(testCase.name.utf8)
            let definition = fontV13Definition(payloads: [
                ("RecoveryGap.ttf", payloadData, .runtimeNanum)
            ])
            try fontV13WritePayloadSources(
                definition,
                dataByName: ["RecoveryGap.ttf": payloadData],
                sourceRoot: fixture.sourceRoot
            )
            let profile = fontV13Profile(
                definition: definition,
                sourceRoot: fixture.sourceRoot,
                blockedOperation: testCase.blocked,
                interruptAfter: testCase.interrupted
            )

            do {
                _ = try await profile.apply(
                    runtimeExecutable: fixture.runtime,
                    prefix: fixture.prefix,
                    logDirectory: fixture.logs
                )
                XCTFail("ownership update seam must stop before payload mutation")
            } catch let error as WindowsFontCompatibilityProfileError {
                if testCase.expectsInterruption {
                    guard case .interruptedAfterOperation = error else {
                        return XCTFail("unexpected error: \(error)")
                    }
                } else {
                    guard case .commitCleanupDurabilityUnknown = error else {
                        return XCTFail("unexpected error: \(error)")
                    }
                }
            }

            let payloadID = try XCTUnwrap(definition.payloads.first?.descriptorID)
            XCTAssertEqual(
                try fontV13CommittedOwnership(
                    key: "committedOwnedFileIDs",
                    prefix: fixture.prefix
                ),
                [payloadID]
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath:
                fixture.prefix.appending(
                    path: "drive_c/windows/Fonts/RecoveryGap.ttf"
                ).path
            ))
            let ownershipStage = fixture.prefix.appending(
                path: "drive_c/.forgeplay-windows-font-compatibility-v5.scratch/" +
                    "00000000-0000-4000-8000-000000000013/marker/" +
                    "journal-ownership-update.json"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: ownershipStage.path))

            let repair = fontV13Profile(
                definition: definition,
                sourceRoot: fixture.sourceRoot
            )
            let repairResult = try await repair.apply(
                runtimeExecutable: fixture.runtime,
                prefix: fixture.prefix,
                logDirectory: fixture.logs
            )
            XCTAssertNil(repairResult)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ownershipStage.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath:
                fontV13JournalURL(fixture.prefix).path
            ))
            XCTAssertTrue(FileManager.default.fileExists(atPath:
                fontV13MarkerURL(fixture.prefix).path
            ))
        }
    }

    func testWindowsFontV13MalformedOrWrongModeJournalIsRetainedWithoutMutation() async throws {
        let malformedCases: [(String, Data)] = [
            ("missing-keys", Data("{}\n".utf8)),
            ("unknown-key", Data("{\"unknown\":true}\n".utf8)),
            ("missing-final-newline", Data("{}".utf8)),
            ("noncanonical-json", Data("{ \"schemaVersion\" : 2 }\n".utf8))
        ]
        for (name, bytes) in malformedCases {
            let fixture = try fontV13MakeLifecycleFixture("malformed-\(name)")
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let journal = fontV13JournalURL(fixture.prefix)
            try bytes.write(to: journal)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: journal.path
            )
            let profile = fontV13Profile(
                definition: fontV13Definition(),
                sourceRoot: fixture.sourceRoot
            )
            do {
                _ = try await profile.apply(
                    runtimeExecutable: fixture.runtime,
                    prefix: fixture.prefix,
                    logDirectory: fixture.logs
                )
                XCTFail("malformed journal must fail closed: \(name)")
            } catch {
                XCTAssertEqual(
                    error as? WindowsFontCompatibilityProfileError,
                    .malformedLifecycleEvidence
                )
            }
            XCTAssertEqual(try Data(contentsOf: journal), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath:
                fixture.prefix.appending(path: "drive_c/ForgePlay").path))
        }

        let modeFixture = try fontV13MakeLifecycleFixture("wrong-mode")
        defer { try? FileManager.default.removeItem(at: modeFixture.root) }
        let generatingProfile = fontV13Profile(
            definition: fontV13Definition(),
            sourceRoot: modeFixture.sourceRoot,
            blockedOperation: .journalParentDirectoryFSync
        )
        do {
            _ = try await generatingProfile.apply(
                runtimeExecutable: modeFixture.runtime,
                prefix: modeFixture.prefix,
                logDirectory: modeFixture.logs
            )
            XCTFail("fixture journal creation must stop at the injected parent fsync")
        } catch let error as WindowsFontCompatibilityProfileError {
            guard case .journalDurabilityFailed = error else {
                return XCTFail("unexpected fixture setup error: \(error)")
            }
        }
        let journal = fontV13JournalURL(modeFixture.prefix)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: journal.path
        )
        let checkingProfile = fontV13Profile(
            definition: fontV13Definition(),
            sourceRoot: modeFixture.sourceRoot
        )
        do {
            _ = try await checkingProfile.apply(
                runtimeExecutable: modeFixture.runtime,
                prefix: modeFixture.prefix,
                logDirectory: modeFixture.logs
            )
            XCTFail("wrong-mode journal must fail closed")
        } catch {
            XCTAssertEqual(
                error as? WindowsFontCompatibilityProfileError,
                .malformedLifecycleEvidence
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }

    private func fontV13LegacyV4Definition() -> WindowsFontLifecycleDefinition {
        let targetIDs = Set(
            WindowsFontCompatibilityProfileContract.legacyV4RegistryReplacements
                .map { $0.target.descriptorID }
        )
        return fontV13Definition(
            registryRequirements: WindowsFontCompatibilityProfileContract.definition
                .registryRequirementsInDescriptorOrder.filter {
                    targetIDs.contains($0.descriptorID)
                }
        )
    }

    private func fontV13InstallExactLegacyV4Payloads(prefix: URL) throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundledWine = repositoryRoot.appending(
            path: "Resources/Runners/ForgePlayRuntime/wine/bin/wine"
        )
        let bundledFonts = try XCTUnwrap(
            WindowsFontCompatibilityProfileContract.resourceDirectory(for: bundledWine)
        )
        let fonts = prefix.appending(
            path: "drive_c/windows/Fonts",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: fonts,
            withIntermediateDirectories: true
        )
        for payload in WindowsFontCompatibilityProfileContract.fontPayloads
            .filter({ $0.sourceRole == .runtimeNanum }) {
            try FileManager.default.copyItem(
                at: bundledFonts.appending(path: payload.fileName),
                to: fonts.appending(path: payload.fileName)
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: fonts.appending(path: payload.fileName).path
            )
        }
    }

    private func fontV13InstallProductionPayloadSources(at destination: URL) throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundledWine = repositoryRoot.appending(
            path: "Resources/Runners/ForgePlayRuntime/wine/bin/wine"
        )
        let runtimeFonts = try XCTUnwrap(
            WindowsFontCompatibilityProfileContract.resourceDirectory(for: bundledWine)
        )
        let appFonts = repositoryRoot.appending(
            path: "Resources/Fonts/ForgePlayNotoV1",
            directoryHint: .isDirectory
        )
        for payload in WindowsFontCompatibilityProfileContract.fontPayloads {
            let sourceRoot = payload.sourceRole == .runtimeNanum
                ? runtimeFonts
                : appFonts
            try FileManager.default.copyItem(
                at: sourceRoot.appending(path: payload.fileName),
                to: destination.appending(path: payload.fileName)
            )
        }
    }

    private func fontV13InstallExactLegacyV4Evidence(prefix: URL) throws {
        try fontV13InstallExactLegacyV4Payloads(prefix: prefix)
        let marker = fontV13LegacyV4MarkerURL(prefix)
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try WindowsFontCompatibilityProfileContract.legacyV4MarkerData.write(
            to: marker
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: marker.path
        )
    }

    private func fontV13LegacyV4MarkerURL(_ prefix: URL) -> URL {
        prefix.appending(
            path: "drive_c/ForgePlay/FontCompatibility/" +
                "forgeplay-windows-font-compatibility-v4.txt"
        )
    }

    private func fontV13FreshWineBaselineEntries() ->
        [WindowsFontRegistryRequirement] {
        WindowsFontCompatibilityProfileContract.freshWineRegistryReplacements
            .map(\.baseline) +
            WindowsFontCompatibilityProfileContract.freshWineAlreadyTargetRequirements
    }

    private func fontV13FreshWineBaselineDefinition() ->
        WindowsFontLifecycleDefinition {
        let requirementIDs = Set(
            WindowsFontCompatibilityProfileContract.freshWineRegistryReplacements
                .map { $0.target.descriptorID } +
            WindowsFontCompatibilityProfileContract.freshWineAlreadyTargetRequirements
                .map(\.descriptorID)
        )
        return fontV13Definition(
            registryRequirements: WindowsFontCompatibilityProfileContract.definition
                .registryRequirementsInDescriptorOrder.filter {
                    requirementIDs.contains($0.descriptorID)
                }
        )
    }

    private func fontV13FreshWineBaselineProfile(
        definition: WindowsFontLifecycleDefinition,
        sourceRoot: URL,
        store: WindowsFontFreshBaselineRegistryStore,
        interruptAfter: WindowsFontLifecycleOperationKind? = nil
    ) -> WindowsFontCompatibilityProfile {
        fontV13Profile(
            definition: definition,
            sourceRoot: sourceRoot,
            interruptAfter: interruptAfter,
            runnerActionExecutor: { operation, action in
                try store.perform(operation: operation, action: action)
                return self.fontV13ProcessResult(exitCode: 0)
            }
        )
    }

    private func fontV13ProductionSizedResources() ->
        [WindowsFontLifecycleOperationKind: [String]] {
        let payloadIDs = WindowsFontCompatibilityProfileContract.definition
            .payloadsInDescriptorOrder.map(\.descriptorID)
        let registryIDs = WindowsFontCompatibilityProfileContract.definition
            .registryRequirementsInDescriptorOrder.map(\.descriptorID)
        let replacementIDs = WindowsFontCompatibilityProfileContract
            .freshWineRegistryReplacements.map(\.replacementID)
        let replacementByTargetID = Dictionary(uniqueKeysWithValues:
            WindowsFontCompatibilityProfileContract.freshWineRegistryReplacements.map {
                ($0.target.descriptorID, $0.replacementID)
            }
        )
        let freshAlreadyTargetIDs = Set(WindowsFontCompatibilityProfileContract
            .freshWineAlreadyTargetRequirements.map(\.descriptorID))
        let createdRegistryIDs = registryIDs.filter {
            replacementByTargetID[$0] == nil &&
                !freshAlreadyTargetIDs.contains($0)
        }
        let registryMutationIDs = registryIDs.compactMap { requirementID in
            if let replacementID = replacementByTargetID[requirementID] {
                return replacementID
            }
            return freshAlreadyTargetIDs.contains(requirementID)
                ? nil
                : requirementID
        }
        let orderedReplacementIDs = registryMutationIDs.filter {
            replacementIDs.contains($0)
        }
        let scratchRoot = ".forgeplay-windows-font-compatibility-v5.scratch/" +
            "00000000-0000-4000-8000-000000000013"
        let directories = [
            ".forgeplay-windows-font-compatibility-v5.scratch",
            "ForgePlay",
            scratchRoot,
            "ForgePlay/FontCompatibility",
            "windows/Fonts",
            "\(scratchRoot)/marker",
            "\(scratchRoot)/payload"
        ]
        let reverseDirectories = [
            "\(scratchRoot)/payload",
            "\(scratchRoot)/marker",
            "windows/Fonts",
            "ForgePlay/FontCompatibility",
            scratchRoot,
            "ForgePlay",
            ".forgeplay-windows-font-compatibility-v5.scratch"
        ]
        let boundStages = (payloadIDs.sorted().map {
            "\(scratchRoot)/payload/\($0).font-stage"
        } + [
            "\(scratchRoot)/marker/forgeplay-windows-font-compatibility-v5.marker-stage",
            "\(scratchRoot)/marker/journal-ownership-update.json"
        ]).sorted(by: >)
        var resources: [WindowsFontLifecycleOperationKind: [String]] = [:]
        for kind in WindowsFontLifecycleOperationKind.allCases {
            resources[kind] = ["singleton-\(kind.rawValue)"]
        }
        resources[.plannedDirectoryCreateVerify] = directories
        resources[.plannedDirectoryContainingParentFSync] = directories
        resources[.payloadStageExclusiveCreate] = payloadIDs
        resources[.payloadAuthenticatedSourceCopy] = payloadIDs
        resources[.payloadStageFSyncHashVerify] = payloadIDs
        let ownershipResources = payloadIDs + registryMutationIDs
        resources[.committedOwnershipStageExclusiveCreate] = ownershipResources
        resources[.committedOwnershipStageCompleteWrite] = ownershipResources
        resources[.committedOwnershipStageFileFSync] = ownershipResources
        resources[.committedOwnershipStageClose] = ownershipResources
        resources[.committedOwnershipStageReopenCanonicalVerify] = ownershipResources
        resources[.committedOwnershipExchange] = ownershipResources
        resources[.committedOwnershipDriveCFSync] = ownershipResources
        resources[.committedOwnershipStaleStageUnlink] = ownershipResources
        resources[.committedOwnershipUpdateParentFSync] = ownershipResources
        resources[.committedOwnershipUpdateParentClose] = ownershipResources
        resources[.committedOwnershipCanonicalReread] = ownershipResources
        resources[.payloadNoOverwriteDestinationPublish] = payloadIDs
        resources[.payloadPublicationStageParentFSync] = payloadIDs
        resources[.payloadPublicationDestinationParentFSync] = payloadIDs
        resources[.committedDirectoryContainingParentFSync] = directories
        resources[.committedPayloadStageParentFSync] = payloadIDs
        resources[.committedPayloadDestinationParentFSync] = payloadIDs
        resources[.markerPublicationStageParentFSync] = ["\(scratchRoot)/marker"]
        resources[.markerParentDirectoryFSync] = ["ForgePlay/FontCompatibility"]
        resources[.committedMarkerStageParentFSync] = ["\(scratchRoot)/marker"]
        resources[.committedMarkerParentFSync] = ["ForgePlay/FontCompatibility"]
        resources[.registrySet] = registryMutationIDs
        resources[.ownedRegistryDelete] = Array(createdRegistryIDs.reversed())
        resources[.replacedRegistryRestore] = Array(orderedReplacementIDs.reversed())
        resources[.ownedFileDelete] = Array(payloadIDs.reversed())
        resources[.ownedFileDeletionParentFSync] = Array(payloadIDs.reversed())
        resources[.boundStageDelete] = boundStages
        resources[.plannedDirectoryDelete] = reverseDirectories
        resources[.plannedDirectoryDeletionContainingParentFSync] = reverseDirectories
        return resources
    }

    private func fontV13ProcessResult(exitCode: Int32) -> ProcessRunResult {
        let logs = URL(fileURLWithPath: "/forgeplay-fixture/logs")
        return ProcessRunResult(
            actionName: "font-v13-fixture",
            executable: URL(fileURLWithPath: "/forgeplay-fixture/wine"),
            arguments: [],
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            exitCode: exitCode,
            stdoutLog: logs.appending(path: "stdout.log"),
            stderrLog: logs.appending(path: "stderr.log"),
            didTimeOut: false
        )
    }

    private func fontV13ResetFixtureRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlay-WindowsFont-v13-\(name)",
            directoryHint: .isDirectory
        )
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func fontV13MakeLifecycleFixture(_ name: String) throws -> (
        root: URL,
        prefix: URL,
        sourceRoot: URL,
        logs: URL,
        runtime: URL
    ) {
        let root = try fontV13ResetFixtureRoot(name)
        let prefix = root.appending(path: "prefix", directoryHint: .isDirectory)
        let driveC = prefix.appending(path: "drive_c", directoryHint: .isDirectory)
        let sourceRoot = root.appending(path: "sources", directoryHint: .isDirectory)
        let logs = root.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: driveC.appending(path: "windows", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let registryHeader = Data("WINE REGISTRY Version 2\n".utf8)
        try registryHeader.write(to: prefix.appending(path: "user.reg"))
        try registryHeader.write(to: prefix.appending(path: "system.reg"))
        return (
            root,
            prefix,
            sourceRoot,
            logs,
            root.appending(path: "fixture-wine")
        )
    }

    private func fontV13Definition(
        payloads: [(String, Data, WindowsFontPayloadSourceRole)] = [],
        registryRequirements: [WindowsFontRegistryRequirement] = []
    ) -> WindowsFontLifecycleDefinition {
        let descriptors = payloads.map { payload in
            let (fileName, data, sourceRole) = payload
            return WindowsFontPayloadDescriptor(
                sourceRole: sourceRole,
                fileName: fileName,
                sha256: SHA256.hash(data: data).map {
                    String(format: "%02x", $0)
                }.joined(),
                registryDisplayName: "Fixture \(fileName)",
                registryFileTypeLabel: fileName.hasSuffix(".otf") ? "OpenType" : "TrueType"
            )
        }
        return WindowsFontLifecycleDefinition(
            profileIdentifier: "forgeplay-windows-font-compatibility-v5",
            payloads: descriptors,
            registryRequirements: registryRequirements
        )
    }

    private func fontV13WritePayloadSources(
        _ definition: WindowsFontLifecycleDefinition,
        dataByName: [String: Data],
        sourceRoot: URL
    ) throws {
        for payload in definition.payloads {
            let data = try XCTUnwrap(dataByName[payload.fileName])
            try data.write(to: sourceRoot.appending(path: payload.fileName))
        }
    }

    private func fontV13Profile(
        definition: WindowsFontLifecycleDefinition,
        sourceRoot: URL,
        blockedOperation: WindowsFontLifecycleOperationKind? = nil,
        interruptAfter: WindowsFontLifecycleOperationKind? = nil,
        runnerActionExecutor:
            WindowsFontLifecycleExecutionHooks.RunnerActionExecutor? = nil,
        payloadHashObserver: @escaping (URL) -> Void = { _ in }
    ) -> WindowsFontCompatibilityProfile {
        let hooks = WindowsFontLifecycleExecutionHooks(
            filesystemOperationExecutor: { operation, body in
                if operation.operationKind == blockedOperation {
                    throw WindowsFontV13FixtureError.injected(
                        operation.operationKind,
                        .filesystemThrow
                    )
                }
                try body()
            },
            runnerActionExecutor: runnerActionExecutor ?? {
                _, _ in self.fontV13ProcessResult(exitCode: 0)
            },
            completionObserver: { operation in
                if operation.operationKind == interruptAfter {
                    throw WindowsFontCompatibilityProfileError.interruptedAfterOperation(
                        operation.operationID
                    )
                }
            }
        )
        return WindowsFontCompatibilityProfile(
            definition: definition,
            sourceRootResolver: { _, _ in [
                .runtimeNanum: sourceRoot,
                .appNotoPack: sourceRoot
            ] },
            hooks: hooks,
            transactionIDProvider: {
                UUID(uuidString: "00000000-0000-4000-8000-000000000013")!
            },
            payloadHashObserver: payloadHashObserver
        )
    }

    private func fontV13JournalURL(_ prefix: URL) -> URL {
        prefix.appending(
            path: "drive_c/.forgeplay-windows-font-compatibility-v5.transaction.json"
        )
    }

    private func fontV13MarkerURL(_ prefix: URL) -> URL {
        prefix.appending(
            path: "drive_c/ForgePlay/FontCompatibility/forgeplay-windows-font-compatibility-v5.txt"
        )
    }

    private func fontV13CommittedOwnership(
        key: String,
        prefix: URL
    ) throws -> [String] {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fontV13JournalURL(prefix))
            ) as? [String: Any]
        )
        return try XCTUnwrap(object[key] as? [String]).sorted()
    }

    func testCompleteAndPartialLibraryAccessChooseSafeReferenceReconciliationPolicy() {
        let complete = SteamLibraryAccessRestoration(
            roots: [],
            unavailableCount: 0,
            bookmarkPersistenceFailed: false
        )
        let partial = SteamLibraryAccessRestoration(
            roots: [],
            unavailableCount: 1,
            bookmarkPersistenceFailed: false
        )
        let persistenceFailure = SteamLibraryAccessRestoration(
            roots: [],
            unavailableCount: 0,
            bookmarkPersistenceFailed: true
        )

        XCTAssertTrue(complete.allowsRemovingStaleReferences)
        XCTAssertFalse(complete.hasSteamReferencesAfterScan(scannedCount: 0, existingCount: 1))
        XCTAssertFalse(partial.allowsRemovingStaleReferences)
        XCTAssertTrue(partial.hasSteamReferencesAfterScan(scannedCount: 0, existingCount: 1))
        XCTAssertFalse(persistenceFailure.allowsRemovingStaleReferences)
        XCTAssertTrue(persistenceFailure.hasSteamReferencesAfterScan(scannedCount: 0, existingCount: 1))

        let incompleteScan = SteamLibraryScanResult(
            games: [],
            skippedInputPaths: ["/Library/steamapps/appmanifest_42.acf"]
        )
        XCTAssertFalse(incompleteScan.isComplete)
        XCTAssertFalse(incompleteScan.allowsRemovingStaleReferences(whenStorageAccessIsComplete: true))
        XCTAssertTrue(
            incompleteScan.hasReferencesAfterScan(
                existingCount: 1,
                whenStorageAccessIsComplete: true
            )
        )
    }

    func testPersistentPrefixSnapshotTreatsMissingLibraryFoldersParentsAsAbsent() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayPersistentPrefixMissingParents-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let manager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        try FileManager.default.createDirectory(
            at: prefix.appending(path: "dosdevices", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let metadata = Data("{\"state\":\"new-prefix\"}".utf8)
        try metadata.write(to: prefix.appending(path: "prefix.json"))

        let snapshot = try manager.captureCompatibilityPersistentPrefixSnapshot(
            prefix: prefix
        )

        XCTAssertEqual(snapshot.prefixMetadata, metadata)
        XCTAssertNil(snapshot.steamLibraryFolders)
        XCTAssertTrue(snapshot.dosDeviceSymlinkTargets.isEmpty)

        try FileManager.default.createDirectory(
            at: prefix.appending(
                path: "drive_c/Program Files (x86)",
                directoryHint: .isDirectory
            ),
            withIntermediateDirectories: true
        )
        let incompleteSnapshot = try manager.captureCompatibilityPersistentPrefixSnapshot(
            prefix: prefix
        )
        XCTAssertEqual(incompleteSnapshot.prefixMetadata, metadata)
        XCTAssertNil(incompleteSnapshot.steamLibraryFolders)
    }

    func testPersistentPrefixSnapshotRejectsExistingSymlinkedLibraryParent() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayPersistentPrefixParentSymlink-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(
            temporaryRoot.appending(path: "Managed", directoryHint: .isDirectory)
        )
        let manager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let driveC = prefix.appending(path: "drive_c", directoryHint: .isDirectory)
        let outside = temporaryRoot.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: prefix.appending(path: "dosdevices", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: driveC, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: outside.appending(path: "Steam/steamapps", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("outside".utf8).write(
            to: outside.appending(path: "Steam/steamapps/libraryfolders.vdf")
        )
        try FileManager.default.createSymbolicLink(
            at: driveC.appending(path: "Program Files (x86)"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try manager.captureCompatibilityPersistentPrefixSnapshot(prefix: prefix)
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("persistent-prefix-parent-containment"),
                "Unexpected containment failure: \(error)"
            )
        }
    }

    func testPersistentPrefixRestoreRecreatesMissingParentsAndRestoresFiles() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayPersistentPrefixRestoreParents-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let manager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let libraryFolders = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps/libraryfolders.vdf"
        )
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: libraryFolders.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let metadata = Data("{\"state\":\"before\"}".utf8)
        let libraries = Data("\"libraryfolders\" { }".utf8)
        try metadata.write(to: prefix.appending(path: "prefix.json"))
        try libraries.write(to: libraryFolders)
        try FileManager.default.createSymbolicLink(
            atPath: dosdevices.appending(path: "c:").path,
            withDestinationPath: "../drive_c"
        )
        let snapshot = try manager.captureCompatibilityPersistentPrefixSnapshot(
            prefix: prefix
        )

        try FileManager.default.removeItem(
            at: prefix.appending(path: "drive_c", directoryHint: .isDirectory)
        )
        try Data("changed".utf8).write(to: prefix.appending(path: "prefix.json"))

        try manager.restoreCompatibilityPersistentPrefixSnapshot(
            snapshot,
            prefix: prefix
        )

        XCTAssertEqual(try Data(contentsOf: prefix.appending(path: "prefix.json")), metadata)
        XCTAssertEqual(try Data(contentsOf: libraryFolders), libraries)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: dosdevices.appending(path: "c:").path
            ),
            "../drive_c"
        )
        XCTAssertEqual(
            try manager.captureCompatibilityPersistentPrefixSnapshot(prefix: prefix),
            snapshot
        )
    }

    func testPersistentPrefixRestoreRejectsSymlinkedLibraryFileWithoutTouchingTarget() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayPersistentPrefixRestoreSymlink-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let manager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let libraryFolders = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps/libraryfolders.vdf"
        )
        try FileManager.default.createDirectory(
            at: prefix.appending(path: "dosdevices", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: libraryFolders.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let metadataURL = prefix.appending(path: "prefix.json")
        try Data("baseline".utf8).write(to: libraryFolders)
        try Data("metadata baseline".utf8).write(to: metadataURL)
        let snapshot = try manager.captureCompatibilityPersistentPrefixSnapshot(
            prefix: prefix
        )
        let outside = temporaryRoot.appending(path: "outside.vdf")
        let outsideData = Data("must-not-change".utf8)
        try outsideData.write(to: outside)
        try FileManager.default.removeItem(at: libraryFolders)
        try FileManager.default.createSymbolicLink(
            at: libraryFolders,
            withDestinationURL: outside
        )
        let changedMetadata = Data("metadata changed after snapshot".utf8)
        try changedMetadata.write(to: metadataURL)

        XCTAssertThrowsError(
            try manager.restoreCompatibilityPersistentPrefixSnapshot(
                snapshot,
                prefix: prefix
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("persistent-prefix-restore-entry-type"),
                "Unexpected restore failure: \(error)"
            )
        }
        XCTAssertEqual(try Data(contentsOf: metadataURL), changedMetadata)
        XCTAssertEqual(try Data(contentsOf: outside), outsideData)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: libraryFolders.path),
            outside.path
        )

        try FileManager.default.removeItem(at: libraryFolders)
        try FileManager.default.createDirectory(at: libraryFolders, withIntermediateDirectories: false)
        XCTAssertThrowsError(
            try manager.restoreCompatibilityPersistentPrefixSnapshot(
                snapshot,
                prefix: prefix
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("persistent-prefix-restore-entry-type"),
                "Unexpected foreign-entry restore failure: \(error)"
            )
        }
        XCTAssertEqual(try Data(contentsOf: metadataURL), changedMetadata)
        XCTAssertTrue(
            FileSystemItemPolicy.isNonSymlinkDirectory(
                libraryFolders,
                fileManager: .default
            )
        )
    }

    func testCancelledRollbackTaskStillRestoresPersistentPrefixSnapshot() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayPersistentPrefixCancelledRollback-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let manager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let libraryFolders = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps/libraryfolders.vdf"
        )
        try FileManager.default.createDirectory(
            at: prefix.appending(path: "dosdevices", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let metadata = Data("baseline".utf8)
        try metadata.write(to: prefix.appending(path: "prefix.json"))
        let snapshot = try manager.captureCompatibilityPersistentPrefixSnapshot(
            prefix: prefix
        )
        try FileManager.default.createDirectory(
            at: libraryFolders.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("launch mutation".utf8).write(to: libraryFolders)
        try Data("changed".utf8).write(to: prefix.appending(path: "prefix.json"))

        let rollback = Task {
            try manager.restoreCompatibilityPersistentPrefixSnapshot(
                snapshot,
                prefix: prefix
            )
        }
        rollback.cancel()
        try await rollback.value

        XCTAssertTrue(rollback.isCancelled)
        XCTAssertEqual(try Data(contentsOf: prefix.appending(path: "prefix.json")), metadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryFolders.path))
        XCTAssertEqual(
            try manager.captureCompatibilityPersistentPrefixSnapshot(prefix: prefix),
            snapshot
        )
    }

    private func makeSteamManager(
        pathManager: PathManager,
        bootstrapProgressIdleTimeout: TimeInterval = 900,
        processEvidenceTimeout: TimeInterval = 0,
        processEvidencePollInterval: TimeInterval = 0.1,
        steamUIStartupObservationTimeout: TimeInterval = 0,
        steamUIStartupObservationPollInterval: TimeInterval = 0.1,
        processSnapshotProvider: @escaping () -> SteamLaunchProcessSnapshot = {
            SteamLaunchProcessSnapshot(processes: [])
        },
        detachedHandoffManagedWineReadbackProvider:
            SteamManager.DetachedHandoffManagedWineReadbackProvider? = nil,
        managedWineLaunchProcessIdentityProvider:
            SteamManager.ManagedWineLaunchProcessIdentityProvider? = { _, _ in [] },
        managedWineJournalProcessSnapshotProvider:
            SteamManager.ManagedWineJournalProcessSnapshotProvider? = nil,
        screenEvidenceProvider: ((ProcessRunResult) -> SteamLaunchScreenEvidence)? = nil,
        gameInputProtectionDriverFactory:
            SteamManager.GameInputProtectionDriverFactory? = nil,
        gameInputProtectionPolicyStore: GameInputProtectionPolicyStore =
            GameInputProtectionPolicyStore(),
        steamClientServicePreparer:
            SteamManager.SteamClientServicePreparer? = { _, _, _ in },
        runtimeLaunchObjectIdentityProvider:
            @escaping SafeProcessRunner.RuntimeLaunchObjectIdentityProvider = {
                _ in nil
            }
    ) -> SteamManager {
        SteamManager(
            pathManager: pathManager,
            runner: makeCuratedRuntimeRunner(
                runtimeLaunchObjectIdentityProvider:
                    runtimeLaunchObjectIdentityProvider
            ),
            processSnapshotProvider: processSnapshotProvider,
            processEvidenceTimeout: processEvidenceTimeout,
            processEvidencePollInterval: processEvidencePollInterval,
            renderingObservationTimeout: 0,
            bootstrapProgressIdleTimeout: bootstrapProgressIdleTimeout,
            steamUIStartupObservationTimeout: steamUIStartupObservationTimeout,
            steamUIStartupObservationPollInterval: steamUIStartupObservationPollInterval,
            detachedHandoffManagedWineReadbackProvider:
                detachedHandoffManagedWineReadbackProvider,
            managedWineLaunchProcessIdentityProvider:
                managedWineLaunchProcessIdentityProvider,
            managedWineJournalProcessSnapshotProvider:
                managedWineJournalProcessSnapshotProvider,
            gameInputProtectionDriverFactory:
                gameInputProtectionDriverFactory,
            screenEvidenceProvider: screenEvidenceProvider,
            gameInputProtectionPolicyStore:
                gameInputProtectionPolicyStore,
            steamClientServicePreparer: steamClientServicePreparer
        )
    }

    private static func repositoryRoot() -> URL {
        var candidate = URL(fileURLWithPath: #filePath)
        while candidate.path != "/" {
            candidate.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: candidate.appending(path: "ForgePlay.xcodeproj").path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    func testLiveBundledForgePlayRuntimeLaunchesWindowsSteamWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FORGEPLAY_LIVE_BUNDLED_STEAM"] == "1" else {
            throw XCTSkip("Set FORGEPLAY_LIVE_BUNDLED_STEAM=1 to run the live bundled ForgePlay Runtime Steam UI conformance check.")
        }

        let runnerPath = environment["FORGEPLAY_LIVE_BUNDLED_RUNNER"] ??
            Self.repositoryRoot()
                .appending(path: "Resources/Runners/ForgePlayRuntime/wine/bin/wine")
                .path
        let runner = URL(fileURLWithPath: runnerPath)
        XCTAssertFalse(
            ExternalApplicationRunnerPolicy.isUnsupportedRunnerExecutable(runner),
            "Bundled live validation must use the ForgePlay-owned runtime: \(runner.path)"
        )

        let managedRoot = URL(fileURLWithPath: environment["FORGEPLAY_LIVE_MANAGED_ROOT"] ??
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/ForgePlay", directoryHint: .isDirectory)
                .path,
            isDirectory: true
        )
        let pathManager = PathManager()
        try pathManager.restorePersistedRoot(managedRoot)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let steamExecutable = prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
        XCTAssertTrue(
            FileSystemItemPolicy.isRegularNonSymlinkFile(steamExecutable),
            "Live bundled validation requires Windows Steam already installed in \(prefix.path)"
        )

        let steamManager = SteamManager(pathManager: pathManager, runner: SafeProcessRunner())
        let result = try await steamManager.launchSteam(
            runtimeExecutable: runner,
            verificationMode: .conformance,
            rendererPolicy: .d3dMetal
        )
        let diagnosticPath = result.diagnosticLog?.path ?? "<missing>"

        XCTAssertTrue(
            result.succeeded,
            [
                "ForgePlay live bundled runtime Steam launch failed.",
                "runner=\(runner.path)",
                "prefix=\(prefix.path)",
                "stdout=\(result.stdoutLog.path)",
                "stderr=\(result.stderrLog.path)",
                "diagnostic=\(diagnosticPath)",
                "exitCode=\(result.exitCode)",
                "didTimeOut=\(result.didTimeOut)"
            ].joined(separator: "\n")
        )
        XCTAssertNotNil(result.diagnosticLog)
    }

    func testLiveAppServiceKeepsOperationalSteamRunningWithoutScreenCaptureWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FORGEPLAY_LIVE_BUNDLED_STEAM_OPERATIONAL"] == "1" else {
            throw XCTSkip("Set FORGEPLAY_LIVE_BUNDLED_STEAM_OPERATIONAL=1 to run the live app-service Steam launch check.")
        }

        let runner = URL(fileURLWithPath: environment["FORGEPLAY_LIVE_BUNDLED_RUNNER"] ??
            Self.repositoryRoot()
                .appending(path: "Resources/Runners/ForgePlayRuntime/wine/bin/wine")
                .path)
        let managedRoot = URL(
            fileURLWithPath: environment["FORGEPLAY_LIVE_MANAGED_ROOT"] ??
                FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: "Library/Application Support/ForgePlay", directoryHint: .isDirectory)
                    .path,
            isDirectory: true
        )
        let services = AppServices()
        try services.pathManager.restorePersistedRoot(managedRoot)

        let result = try await services.steamPrefixService.launchSteam(
            runtimeExecutable: runner,
            steamClientLanguage: .english,
            rendererPolicySelection: .d3dMetal,
            networkSelection: .standard,
            audioInputSelection: .enabled
        )
        let diagnostics = try result.diagnosticLog.map {
            try String(contentsOf: $0, encoding: .utf8)
        } ?? ""

        XCTAssertTrue(result.succeeded, diagnostics)
        XCTAssertEqual(result.steamUIVerificationState, .launchedButUnverified)
        XCTAssertTrue(diagnostics.contains("Status: LAUNCHED"), diagnostics)
        XCTAssertFalse(diagnostics.contains("Post-failure Steam Prefix process shutdown:"), diagnostics)
        XCTAssertFalse(diagnostics.contains("Status: SUCCESS"), diagnostics)
    }

    func testMacOSSteamProcessSnapshotDetectsOnlyHostSteamProcesses() {
        let output = """
          101 /Users/tester/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx
          102 /Users/tester/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/Steam Helper.app/Contents/MacOS/Steam Helper --type=renderer
          103 C:\\Program Files (x86)\\Steam\\steam.exe -no-cef-sandbox
          104 C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win64\\steamwebhelper.exe --no-sandbox
          105 /Volumes/Runtime/bin/wine C:\\Program Files (x86)\\Steam\\steam.exe
        """

        let processes = MacOSSteamProcessSnapshot.parsePSOutput(output)

        XCTAssertEqual(processes.map(\.processID), [101, 102])
        XCTAssertTrue(processes[0].command.contains("steam_osx"))
        XCTAssertFalse(processes.contains { $0.command.contains("steamwebhelper.exe") })
    }

    func testMacOSSteamProcessSnapshotReportsNewHostSteamProcesses() {
        let before = MacOSSteamProcessSnapshot(processes: [
            MacOSSteamProcess(
                processID: 101,
                command: "/Users/tester/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx"
            )
        ])
        let after = MacOSSteamProcessSnapshot(processes: before.processes + [
            MacOSSteamProcess(
                processID: 202,
                command: "/Users/tester/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/Steam Helper.app/Contents/MacOS/Steam Helper"
            )
        ])

        let newProcesses = after.newProcesses(since: before)

        XCTAssertEqual(newProcesses.map(\.processID), [202])
    }

    func testSteamLaunchProcessSnapshotKeepsSameNumericPIDAcrossNamespaces() {
        let darwinProcess = SteamLaunchObservedProcess(
            processID: 304,
            command: "/Applications/ForgePlay.app/Contents/Resources/Runners/ForgePlayRuntime/wine/bin/wine"
        )
        let windowsProcess = SteamLaunchObservedProcess(
            processID: 304,
            command: "C:\\Program Files (x86)\\Steam\\steamwebhelper.exe",
            evidenceSource: .processCreationObservation
        )
        let before = SteamLaunchProcessSnapshot(processes: [darwinProcess])
        let after = SteamLaunchProcessSnapshot(processes: [darwinProcess, windowsProcess])

        let newProcesses = after.newProcesses(since: before)

        XCTAssertEqual(newProcesses, [windowsProcess])
        XCTAssertEqual(newProcesses.first?.identifier.namespace, .windows)
    }

    func testBareDarwinSteamCommandRequiresExactManagedJournalPIDBinding() {
        let target = SteamLaunchTarget(
            expectedRunnerPath: URL(fileURLWithPath: "/Runtime/wine/bin/wine"),
            expectedPrefixPath: URL(fileURLWithPath: "/Managed/SteamShared"),
            expectedSteamExecutablePath: URL(
                fileURLWithPath:
                    "/Managed/SteamShared/drive_c/Program Files (x86)/Steam/steam.exe"
            )
        )
        let bareSystemSnapshot = SteamLaunchProcessSnapshot(processes: [
            SteamLaunchObservedProcess(
                processID: 73_101,
                command:
                    #"/Runtime/wine/bin/wine C:\Program Files (x86)\Steam\steam.exe -no-cef-sandbox"#,
                processStartedAtUnixMicroseconds: 910_001
            )
        ])

        XCTAssertFalse(
            bareSystemSnapshot.containsExpectedPrefixSteamClientProcess(
                for: target
            )
        )
        let unboundSamePrefixSnapshot = SteamLaunchProcessSnapshot(
            processes: [
                SteamLaunchObservedProcess(
                    processID: 73_100,
                    command:
                        #"/Runtime/wine/bin/wine C:\Program Files (x86)\Steam\steam.exe WINEPREFIX=/Managed/SteamShared"#,
                    processStartedAtUnixMicroseconds: 910_000
                )
            ]
        )
        XCTAssertTrue(
            unboundSamePrefixSnapshot.containsExpectedPrefixSteamClientProcess(
                for: target
            ),
            "the broad diagnostic predicate still recognizes a current same-prefix row"
        )
        XCTAssertFalse(
            unboundSamePrefixSnapshot
                .containsVerifiedCurrentRunSteamClientProcess(for: target),
            "an unbound same-prefix row must not extend the current launch's updater lifecycle"
        )
        XCTAssertFalse(
            unboundSamePrefixSnapshot
                .containsVerifiedCurrentRunSteamProcess(for: target),
            "an unbound same-prefix row must not satisfy the operational launch gate"
        )
        XCTAssertFalse(
            bareSystemSnapshot
                .bindingManagedWineJournalProcessIdentities([
                    ManagedWineLaunchProcessIdentity(
                        processID: 73_102,
                        processStartedAtUnixMicroseconds: 910_001,
                        executableURL: URL(
                            fileURLWithPath: "/Runtime/wine/bin/wine.bin"
                        )
                    )
                ])
                .containsExpectedPrefixSteamClientProcess(for: target),
            "a different journal PID must not authorize the captured command"
        )
        XCTAssertFalse(
            bareSystemSnapshot
                .bindingManagedWineJournalProcessIdentities([
                    ManagedWineLaunchProcessIdentity(
                        processID: 73_101,
                        processStartedAtUnixMicroseconds: 910_002,
                        executableURL: URL(
                            fileURLWithPath: "/Runtime/wine/bin/wine.bin"
                        )
                    )
                ])
                .containsExpectedPrefixSteamClientProcess(for: target),
            "a reused numeric PID with a different kernel start identity must not authorize an older snapshot row"
        )
        let verified = bareSystemSnapshot
            .bindingManagedWineJournalProcessIdentities([
                ManagedWineLaunchProcessIdentity(
                    processID: 73_101,
                    processStartedAtUnixMicroseconds: 910_001,
                    executableURL: URL(
                        fileURLWithPath: "/Runtime/wine/bin/wine.bin"
                    )
                )
            ])
        XCTAssertTrue(
            verified.containsExpectedPrefixSteamClientProcess(for: target)
        )
        XCTAssertTrue(
            verified.containsVerifiedCurrentRunSteamClientProcess(for: target)
        )
        XCTAssertTrue(
            verified.containsVerifiedCurrentRunSteamProcess(for: target)
        )
        XCTAssertEqual(
            verified.processes.first?.evidenceSource,
            .managedWineJournal
        )
        XCTAssertEqual(
            verified.processes.first?.identifier.namespace,
            .darwin
        )

        let staleCreationOnlyWebHelper = SteamLaunchProcessSnapshot(
            processes: verified.processes + [
                SteamLaunchObservedProcess(
                    processID: 404,
                    command:
                        #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --no-sandbox"#,
                    evidenceSource: .processCreationObservation
                )
            ]
        )
        XCTAssertFalse(
            staleCreationOnlyWebHelper.webHelperCommandLines(
                for: target
            ).isEmpty,
            "append-only creation evidence remains available for diagnostics"
        )
        XCTAssertTrue(
            staleCreationOnlyWebHelper
                .managedWineJournalWebHelperCommandLines(for: target)
                .isEmpty,
            "a departed WebHelper creation row must never become current renderer/UI liveness"
        )
        XCTAssertFalse(
            staleCreationOnlyWebHelper
                .managedWineJournalWebHelperCommandLinesContainRequiredLaunchPolicy(
                    for: target
                ),
            "append-only creation evidence must not satisfy the operational WebHelper policy gate"
        )
    }

    func testExactManagedJournalCaptureAdmitsLiveWineBinWithoutGenericSnapshotRow() {
        let executable = URL(
            fileURLWithPath: "/Runtime/wine/bin/wine.bin"
        )
        let prefix = URL(fileURLWithPath: "/Managed/SteamShared")
        let steamExecutable = URL(
            fileURLWithPath:
                "/Managed/SteamShared/drive_c/Program Files (x86)/Steam/steam.exe"
        )
        let identity = ManagedWineLaunchProcessIdentity(
            processID: 62_454,
            processStartedAtUnixMicroseconds: 1_786_697_624_000_000,
            executableURL: executable
        )
        let managedRead = DarwinProcessSnapshotReader
            .currentManagedWineJournalProcesses(
                [identity],
                processStartTimeProvider: { _ in
                    identity.processStartedAtUnixMicroseconds
                },
                executablePathProvider: { _ in executable.path },
                processArgumentsProvider: { _ in
                    DarwinProcessArguments(
                        arguments: [
                            executable.path,
                            #"C:\Program Files (x86)\Steam\steam.exe"#
                        ],
                        winePrefix: prefix.path
                    )
                }
            )
        let exactSnapshot = SteamLaunchProcessSnapshot(
            processes: managedRead.processes,
            processObservationReadState: managedRead.state,
            processObservationReadIssues: managedRead.issues
        ).merging(SteamLaunchProcessSnapshot(processes: []))
        let target = SteamLaunchTarget(
            expectedRunnerPath: executable.deletingLastPathComponent()
                .appending(path: "wine"),
            expectedPrefixPath: prefix,
            expectedSteamExecutablePath: steamExecutable
        )

        XCTAssertEqual(managedRead.state, .complete)
        XCTAssertEqual(managedRead.processes.count, 1)
        XCTAssertEqual(
            managedRead.processes.first?.evidenceSource,
            .managedWineJournal
        )
        XCTAssertTrue(
            exactSnapshot.containsVerifiedCurrentRunSteamClientProcess(
                for: target
            ),
            "the exact managed PID/start/executable path must capture wine.bin even when generic enumeration returned no row"
        )
        let wrongExecutable = DarwinProcessSnapshotReader
            .currentManagedWineJournalProcesses(
                [identity],
                processStartTimeProvider: { _ in
                    identity.processStartedAtUnixMicroseconds
                },
                executablePathProvider: { _ in
                    "/Runtime/wine/bin/unverified-wine.bin"
                },
                processArgumentsProvider: { _ in
                    DarwinProcessArguments(arguments: [], winePrefix: prefix.path)
                }
            )
        XCTAssertEqual(wrongExecutable.state, .unavailable)
        XCTAssertTrue(wrongExecutable.processes.isEmpty)

        var executableReads = [
            executable.path,
            "/Runtime/wine/bin/replaced-after-arguments.bin"
        ]
        let execTransitionDuringRead = DarwinProcessSnapshotReader
            .currentManagedWineJournalProcesses(
                [identity],
                processStartTimeProvider: { _ in
                    identity.processStartedAtUnixMicroseconds
                },
                executablePathProvider: { _ in
                    executableReads.removeFirst()
                },
                processArgumentsProvider: { _ in
                    DarwinProcessArguments(
                        arguments: [#"C:\Program Files (x86)\Steam\steam.exe"#],
                        winePrefix: prefix.path
                    )
                }
            )
        XCTAssertEqual(execTransitionDuringRead.state, .unavailable)
        XCTAssertTrue(execTransitionDuringRead.processes.isEmpty)
        XCTAssertTrue(execTransitionDuringRead.issues.contains {
            $0.code == .managedWineLaunchProcessVerificationFailed &&
                $0.detail.contains("executable changed while its arguments")
        })

        var startReads = [
            identity.processStartedAtUnixMicroseconds,
            identity.processStartedAtUnixMicroseconds + 1
        ]
        let reusedDuringRead = DarwinProcessSnapshotReader
            .currentManagedWineJournalProcesses(
                [identity],
                processStartTimeProvider: { _ in startReads.removeFirst() },
                executablePathProvider: { _ in executable.path },
                processArgumentsProvider: { _ in
                    DarwinProcessArguments(
                        arguments: [#"C:\Program Files (x86)\Steam\steam.exe"#],
                        winePrefix: prefix.path
                    )
                }
            )
        XCTAssertEqual(reusedDuringRead.state, .unavailable)
        XCTAssertTrue(reusedDuringRead.processes.isEmpty)
    }

    func testWebHelperLaunchPolicyRequiresRootArgumentsWithoutRewritingTypedChildren() {
        let target = SteamLaunchTarget(
            expectedRunnerPath: URL(fileURLWithPath: "/Runtime/wine/bin/wine"),
            expectedPrefixPath: URL(fileURLWithPath: "/Managed/SteamShared"),
            expectedSteamExecutablePath: URL(
                fileURLWithPath:
                    "/Managed/SteamShared/drive_c/Program Files (x86)/Steam/steam.exe"
            )
        )
        let rootCommand = #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --no-sandbox --in-process-gpu --disable-gpu"#
        let typedCommand = #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --type=renderer --no-sandbox"#
        let mixedSnapshot = SteamLaunchProcessSnapshot(processes: [
            SteamLaunchObservedProcess(
                processID: 73_201,
                command: rootCommand,
                evidenceSource: .managedWineJournal
            ),
            SteamLaunchObservedProcess(
                processID: 73_202,
                command: typedCommand,
                evidenceSource: .managedWineJournal
            )
        ])

        XCTAssertTrue(
            mixedSnapshot
                .managedWineJournalWebHelperCommandLinesContainRequiredLaunchPolicy(
                    for: target
                )
        )
        XCTAssertTrue(
            mixedSnapshot.webHelperCommandLinesContainRequiredLaunchPolicy(
                for: target
            )
        )

        let typedOnlySnapshot = SteamLaunchProcessSnapshot(processes: [
            SteamLaunchObservedProcess(
                processID: 73_202,
                command:
                    typedCommand + " --in-process-gpu --disable-gpu",
                evidenceSource: .managedWineJournal
            )
        ])
        XCTAssertFalse(
            typedOnlySnapshot
                .managedWineJournalWebHelperCommandLinesContainRequiredLaunchPolicy(
                    for: target
                ),
            "typed Chromium children cannot stand in for the root WebHelper policy"
        )
    }

    func testDarwinProcessArgumentParserKeepsSteamArgumentsAndOnlySelectedEnvironment() throws {
        let executablePath = "/Applications/ForgePlay.app/Contents/Resources/Runners/ForgePlayRuntime/wine/lib/wine/x86_64-unix/wine"
        let arguments = [
            executablePath,
            "C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win64\\steamwebhelper.exe",
            "--type=renderer",
            "--no-sandbox",
            "--in-process-gpu",
            "--disable-gpu"
        ]
        var argumentCount = Int32(arguments.count)
        var data = withUnsafeBytes(of: &argumentCount) { Data($0) }
        func appendCString(_ value: String) {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        appendCString(executablePath)
        data.append(contentsOf: [0, 0])
        arguments.forEach(appendCString)
        appendCString("SECRET_TOKEN=must-not-be-recorded")
        appendCString("WINEPREFIX=/Volumes/Games/Prefixes/SteamShared")
        data.append(0)

        let parsed = try XCTUnwrap(DarwinProcessSnapshotReader.parseProcessArguments(data))
        let command = DarwinProcessSnapshotReader.diagnosticCommandLine(
            executablePath: executablePath,
            processArguments: parsed
        )

        XCTAssertEqual(parsed.arguments, arguments)
        XCTAssertEqual(parsed.winePrefix, "/Volumes/Games/Prefixes/SteamShared")
        XCTAssertTrue(command.contains("steamwebhelper.exe"), command)
        XCTAssertTrue(command.contains("--no-sandbox --in-process-gpu --disable-gpu"), command)
        XCTAssertTrue(command.contains("WINEPREFIX=/Volumes/Games/Prefixes/SteamShared"), command)
        XCTAssertFalse(command.contains("SECRET_TOKEN"), command)
    }

    func testSteamProcessCreationObservationParserAcceptsOnlyCompleteBoundedWebHelperRecords() {
        let command = #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --type=renderer --no-sandbox"#
        let data = Data([
            "FORGEPLAY_PROCESS_V1\t71001\t\(command)",
            "WRONG_PREFIX\t71002\t\(command)",
            "FORGEPLAY_PROCESS_V1\t71003\tC:\\Windows\\notepad.exe",
            "FORGEPLAY_PROCESS_V1\t71004\t\(command)\tSECRET_TOKEN=must-not-be-recorded",
            "FORGEPLAY_PROCESS_V1\t71005\t\(command)"
        ].joined(separator: "\n").utf8)

        let processes = SteamProcessCreationObservationLog.parse(data)

        XCTAssertEqual(processes.map(\.processID), [71_001])
        XCTAssertEqual(processes.first?.command, command)
        XCTAssertEqual(processes.first?.evidenceSource, .processCreationObservation)
        XCTAssertEqual(processes.first?.identifier.namespace, .windows)
        XCTAssertFalse(
            SteamWebHelperLaunchPolicy.commandLineContainsRequiredArguments(command)
        )
        XCTAssertFalse(
            SteamWebHelperLaunchPolicy.commandLineContainsRequiredArguments(
                command + " --in-process-gpu"
            )
        )
        XCTAssertFalse(
            SteamWebHelperLaunchPolicy.commandLineContainsRequiredArguments(
                command + " --disable-gpu"
            )
        )
        XCTAssertFalse(
            SteamWebHelperLaunchPolicy.commandLineContainsRequiredArguments(
                command + " --disable-gpu-compositing"
            )
        )
        XCTAssertTrue(
            SteamWebHelperLaunchPolicy.commandLineContainsRequiredArguments(
                command + " --in-process-gpu --disable-gpu"
            )
        )
        XCTAssertTrue(
            SteamWebHelperLaunchPolicy.isChromiumSubprocessCommandLine(command)
        )
        XCTAssertTrue(
            SteamWebHelperLaunchPolicy.isChromiumSubprocessCommandLine(
                command.replacingOccurrences(
                    of: "--type=renderer",
                    with: "\"--type=renderer\""
                )
            )
        )
        XCTAssertFalse(
            SteamWebHelperLaunchPolicy.rootCommandLineContainsRequiredArguments(
                command + " --in-process-gpu --disable-gpu"
            )
        )
        let rootCommand = command.replacingOccurrences(
            of: " --type=renderer",
            with: ""
        )
        XCTAssertFalse(
            SteamWebHelperLaunchPolicy.isChromiumSubprocessCommandLine(
                rootCommand
            )
        )
        XCTAssertTrue(
            SteamWebHelperLaunchPolicy.rootCommandLineContainsRequiredArguments(
                rootCommand + " --in-process-gpu --disable-gpu"
            )
        )
        XCTAssertFalse(processes.contains { $0.command.contains("SECRET_TOKEN") })
    }

    func testSameLaunchWebHelperLanguageReadbackCoversEverySupportedSteamLanguage() {
        let target = SteamLaunchTarget(
            expectedRunnerPath: URL(fileURLWithPath: "/Runtime/wine"),
            expectedPrefixPath: URL(fileURLWithPath: "/Managed/SteamShared"),
            expectedSteamExecutablePath: URL(
                fileURLWithPath:
                    "/Managed/SteamShared/drive_c/Program Files (x86)/Steam/steam.exe"
            )
        )

        for (index, language) in SteamClientLanguage.allCases.enumerated() {
            let command = #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --type=renderer --no-sandbox -lang=\#(language.webHelperLocaleIdentifier)"#
            let snapshot = SteamLaunchProcessSnapshot(processes: [
                SteamLaunchObservedProcess(
                    processID: Int32(72_000 + index),
                    command: command,
                    evidenceSource: .processCreationObservation
                )
            ])

            let readback = snapshot.webHelperLanguageReadback(
                for: target,
                expected: language
            )

            XCTAssertEqual(readback.state, .matched, language.rawValue)
            XCTAssertTrue(readback.confirms(language), language.rawValue)
            XCTAssertEqual(
                readback.observedLocaleIdentifiers,
                [language.webHelperLocaleIdentifier]
            )
        }
    }

    func testSameLaunchWebHelperLanguageReadbackKeepsMissingEvidencePendingAndRejectsConflict() {
        let target = SteamLaunchTarget(
            expectedRunnerPath: URL(fileURLWithPath: "/Runtime/wine"),
            expectedPrefixPath: URL(fileURLWithPath: "/Managed/SteamShared"),
            expectedSteamExecutablePath: URL(
                fileURLWithPath:
                    "/Managed/SteamShared/drive_c/Program Files (x86)/Steam/steam.exe"
            )
        )
        let koreanCommand = #"C:\Program Files (x86)\Steam\bin\cef\steamwebhelper.exe --no-sandbox "-lang=KO-kr""#
        let englishCommand = #"C:\Program Files (x86)\Steam\bin\cef\steamwebhelper.exe --no-sandbox -lang=en_US"#
        let conflicting = SteamLaunchProcessSnapshot(processes: [
            SteamLaunchObservedProcess(
                processID: 72_101,
                command: koreanCommand,
                evidenceSource: .processCreationObservation
            ),
            SteamLaunchObservedProcess(
                processID: 72_102,
                command: englishCommand,
                evidenceSource: .processCreationObservation
            )
        ]).webHelperLanguageReadback(for: target, expected: .koreana)
        XCTAssertEqual(conflicting.state, .mismatched)
        XCTAssertFalse(conflicting.confirms(.koreana))

        let pending = SteamLaunchProcessSnapshot(processes: [
            SteamLaunchObservedProcess(
                processID: 72_103,
                command: #"C:\Program Files (x86)\Steam\bin\cef\steamwebhelper.exe --no-sandbox"#,
                evidenceSource: .processCreationObservation
            )
        ]).webHelperLanguageReadback(for: target, expected: .koreana)
        XCTAssertEqual(pending.state, .pending)

        let unavailable = SteamLaunchProcessSnapshot(
            processes: [],
            processObservationReadState: .unavailable
        ).webHelperLanguageReadback(for: target, expected: .koreana)
        XCTAssertEqual(unavailable.state, .evidenceUnavailable)
        XCTAssertFalse(unavailable.confirms(.koreana))
    }

    func testSteamProcessCreationObservationParserRecoversNewestCompleteRecordFromOversizedInput() {
        let command = #"C:\Program Files (x86)\Steam\bin\cef\steamwebhelper.exe --type=renderer --no-sandbox"#
        var oversized = Data(repeating: 0x61, count: 1024 * 1024 + 256)
        oversized.append(0x0a)
        oversized.append(contentsOf: "FORGEPLAY_PROCESS_V1\t71009\t\(command)\n".utf8)

        let result = SteamProcessCreationObservationLog.parseResult(oversized)

        XCTAssertEqual(result.processes.map(\.processID), [71_009])
        XCTAssertEqual(result.state, .recovered)
        XCTAssertTrue(result.issues.contains { $0.code == .oversizedTailRecovered })
        XCTAssertTrue(result.issues.contains { $0.code == .leadingPartialRecordDiscarded })
    }

    func testGameRendererObservationParserAcceptsOnlyCompleteKnownPolicyRecords() {
        let executable = #"D:\SteamLibrary\steamapps\common\Game\game.exe"#
        let data = Data([
            "FORGEPLAY_GAME_RENDERER_V1\t72001\td3dMetal | \(executable)",
            "FORGEPLAY_GAME_RENDERER_V1\t72002\tunknown | \(executable)",
            "FORGEPLAY_GAME_RENDERER_V1\t72003\tvulkan | ",
            "FORGEPLAY_PROCESS_V1\t72004\t\(executable)",
            "FORGEPLAY_GAME_RENDERER_V1\t72005\tvulkan | \(executable)"
        ].joined(separator: "\n").utf8)

        let observations = SteamProcessCreationObservationLog.parseGameRendererObservations(data)

        XCTAssertEqual(
            observations,
            [
                SteamGameRendererObservation(
                    processID: 72_001,
                    rendererPolicy: .d3dMetal,
                    executable: executable
                )
            ]
        )
        XCTAssertEqual(observations.first?.executableName, "game.exe")
    }

    func testGameRendererObservationParserPreservesManualD3DMetalRouteEvidence() throws {
        let executable = #"D:\SteamLibrary\steamapps\common\Game\game.exe"#
        let payload = "requested=d3dMetal | applied=d3dMetal | reason=manual-session-selected | " +
            "evidence=selected=d3dMetal | \(executable)"
        let data = Data("FORGEPLAY_GAME_RENDERER_V1\t72006\t\(payload)\n".utf8)

        let observation = try XCTUnwrap(
            SteamProcessCreationObservationLog.parseGameRendererObservations(data).first
        )

        XCTAssertEqual(observation.processID, 72_006)
        XCTAssertEqual(observation.rendererPolicy, .d3dMetal)
        XCTAssertEqual(observation.plannedProfile, "d3dMetal")
        XCTAssertEqual(observation.plannedComponentOwnership, .d3dMetal)
        XCTAssertEqual(observation.plannedComponentsX64, "unreported")
        XCTAssertEqual(observation.plannedComponentsX86, "unreported")
        XCTAssertEqual(observation.actualLoadedState, .unobserved)
        XCTAssertEqual(observation.routingReason, "manual-session-selected")
        XCTAssertEqual(observation.routingEvidence, "selected=d3dMetal")
        XCTAssertEqual(observation.executable, executable)
    }

    func testGameRendererObservationParserPreservesManualDXMTRoute() throws {
        let executable = #"D:\SteamLibrary\steamapps\common\LegacyGame\game.exe"#
        let payload = "requested=dxmt | applied=dxmt | reason=manual-session-selected | " +
            "evidence=selected=dxmt | \(executable)"
        let data = Data("FORGEPLAY_GAME_RENDERER_V1\t72007\t\(payload)\n".utf8)

        let observation = try XCTUnwrap(
            SteamProcessCreationObservationLog.parseGameRendererObservations(data).first
        )

        XCTAssertEqual(observation.processID, 72_007)
        XCTAssertEqual(observation.rendererPolicy, .dxmt)
        XCTAssertEqual(observation.plannedProfile, "dxmt")
        XCTAssertEqual(observation.plannedComponentOwnership, .dxmt)
        XCTAssertEqual(observation.actualLoadedState, .unobserved)
        XCTAssertEqual(observation.routingReason, "manual-session-selected")
        XCTAssertEqual(observation.routingEvidence, "selected=dxmt")
        XCTAssertEqual(observation.executable, executable)
    }

    func testGameRendererObservationParserRejectsHistoricalAutomaticCompositeRoute() {
        let executable = #"D:\SteamLibrary\steamapps\common\SourceGame\launcher.exe"#
        let payload = "requested=automatic | applied=legacy32 | " +
            "planned-profile=LEGACY32 | planned-owner=legacy32 | " +
            "planned-components-x64=d9vk,dxmt,dxvk | " +
            "planned-components-x86=d9vk,dxmt,dxvk | actual-loaded=unobserved | " +
            "reason=automatic-legacy32-ambiguous-imports | " +
            "evidence=pe32;no-direct3d-generation | \(executable)"
        let data = Data("FORGEPLAY_GAME_RENDERER_V1\t72010\t\(payload)\n".utf8)

        XCTAssertTrue(
            SteamProcessCreationObservationLog
                .parseGameRendererObservations(data)
                .isEmpty
        )
    }

    func testGameRendererErrorObservationParserPreservesStageStatusAndPath() throws {
        let path = #"G:\SteamLibrary\steamapps\common\Game\game.exe"#
        let data = Data([
            "FORGEPLAY_GAME_RENDERER_ERROR_V1\t72008\tchild-environment | status=0xC0000005 | \(path)",
            "FORGEPLAY_GAME_RENDERER_ERROR_V1\t72009\tchild-environment | status=not-hex | \(path)"
        ].joined(separator: "\n").appending("\n").utf8)

        let result = SteamProcessCreationObservationLog.parseResult(data)
        let error = try XCTUnwrap(result.gameRendererErrors.first)

        XCTAssertEqual(result.gameRendererErrors.count, 1)
        XCTAssertEqual(error.processID, 72_008)
        XCTAssertEqual(error.stage, "child-environment")
        XCTAssertEqual(error.statusCode, 0xC0000005)
        XCTAssertEqual(error.statusHex, "0xC0000005")
        XCTAssertEqual(error.path, path)
        XCTAssertEqual(result.state, .recovered)
        XCTAssertTrue(result.issues.contains { $0.code == .malformedRecordDiscarded })
    }

    func testGameRendererFallbackParserPreservesVariableFailureAndContinuedLaunch() throws {
        let path = #"G:\SteamLibrary\steamapps\common\Game | Test\game.exe"#
        let data = Data((
            "FORGEPLAY_GAME_RENDERER_ENVIRONMENT_V1\t72014\t" +
                "operation=remove-from-source | " +
                "source=FORGEPLAY_GAME_RENDERER_ENV_DYLD_FRAMEWORK_PATH | " +
                "target=DYLD_FRAMEWORK_PATH | status=0xC000000D\n" +
            "FORGEPLAY_GAME_RENDERER_FALLBACK_V1\t72014\t" +
                "stage=child-environment | status=0xC000000D | " +
                "result=game-identity-environment | path=\(path)\n"
        ).utf8)

        let result = SteamProcessCreationObservationLog.parseResult(data)
        let environmentFailure = try XCTUnwrap(result.gameRendererEnvironmentFailures.first)
        let fallback = try XCTUnwrap(result.gameRendererFallbacks.first)

        XCTAssertEqual(environmentFailure.processID, 72_014)
        XCTAssertEqual(environmentFailure.operation, "remove-from-source")
        XCTAssertEqual(
            environmentFailure.sourceVariable,
            "FORGEPLAY_GAME_RENDERER_ENV_DYLD_FRAMEWORK_PATH"
        )
        XCTAssertEqual(environmentFailure.targetVariable, "DYLD_FRAMEWORK_PATH")
        XCTAssertEqual(environmentFailure.statusHex, "0xC000000D")
        XCTAssertEqual(fallback.processID, 72_014)
        XCTAssertEqual(fallback.stage, "child-environment")
        XCTAssertEqual(fallback.statusHex, "0xC000000D")
        XCTAssertEqual(fallback.result, "game-identity-environment")
        XCTAssertEqual(fallback.path, path)
        XCTAssertEqual(result.state, .complete)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testSessionCompatibilityObservationParserPreservesBaseHelperAndNVAPIBootstrap() throws {
        let helper =
            #"G:\SteamLibrary\steamapps\common\BlueArchive\BlueArchive_Data\Plugins\x86_64\grap\NGService.exe"#
        let data = Data((
            "FORGEPLAY_GAME_RENDERER_BASE_HELPER_V1\t72015\t" +
                "route=base-runtime | reason=host-owned-exact-suffix-rule | " +
                "\(helper)\n" +
            "FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP_V1\t72016\t" +
                "state=initialized | module=nvapi64.dll | " +
                "load-status=0x00000000 | procedure-status=0x00000000 | " +
                "exception-status=0x00000000 | initialize-result=0\n"
        ).utf8)

        let result = SteamProcessCreationObservationLog.parseResult(data)
        let helperObservation = try XCTUnwrap(
            result.gameRendererBaseHelpers.first
        )
        let bootstrap = try XCTUnwrap(
            result.d3dMetalNVAPIBootstraps.first
        )

        XCTAssertEqual(helperObservation.processID, 72_015)
        XCTAssertEqual(helperObservation.route, "base-runtime")
        XCTAssertEqual(
            helperObservation.reason,
            "host-owned-exact-suffix-rule"
        )
        XCTAssertEqual(helperObservation.executable, helper)
        XCTAssertEqual(bootstrap.processID, 72_016)
        XCTAssertEqual(bootstrap.state, .initialized)
        XCTAssertEqual(bootstrap.module, "nvapi64.dll")
        XCTAssertEqual(bootstrap.loadStatus, 0)
        XCTAssertEqual(bootstrap.procedureStatus, 0)
        XCTAssertEqual(bootstrap.exceptionStatus, 0)
        XCTAssertEqual(bootstrap.initializeResult, 0)
        XCTAssertEqual(result.state, .complete)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testSessionCompatibilityObservationParserRejectsInconsistentNVAPIState() {
        let data = Data((
            "FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP_V1\t72017\t" +
                "state=initialized | module=nvapi64.dll | " +
                "load-status=0xC0000135 | procedure-status=0x00000000 | " +
                "exception-status=0x00000000 | initialize-result=0\n"
        ).utf8)

        let result = SteamProcessCreationObservationLog.parseResult(data)

        XCTAssertTrue(result.d3dMetalNVAPIBootstraps.isEmpty)
        XCTAssertEqual(result.state, .recovered)
        XCTAssertTrue(
            result.issues.contains {
                $0.code == .malformedRecordDiscarded
            }
        )
    }

    func testGameLaunchDiagnosticCorrelatesFallbackWithoutClassifyingItAsFatal() throws {
        let executable = #"G:\SteamLibrary\steamapps\common\Fallback Game\game.exe"#
        let observation = SteamProcessCreationObservationLog.parseResult(Data((
            "FORGEPLAY_GAME_RENDERER_ENVIRONMENT_V1\t500\t" +
                "operation=set-from-source | source=FORGEPLAY_GAME_RENDERER_ENV_WINEDLLPATH | " +
                "target=WINEDLLPATH | status=0xC000000D\n" +
            "FORGEPLAY_GAME_RENDERER_FALLBACK_V1\t500\t" +
                "stage=child-environment | status=0xC000000D | " +
                "result=game-identity-environment | path=\(executable)\n"
        ).utf8))
        let startedAt = try steamLogDate(
            year: 2026, month: 7, day: 23, hour: 4, minute: 10, second: 0
        )
        let diagnostic = try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [
                "[2026-07-23 04:10:00] AppID 777 adding PID 1600 as a tracked process " +
                    "\"\"\(executable)\"\""
            ],
            consoleLines: [],
            processObservation: observation,
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(2)
        ))

        XCTAssertEqual(diagnostic.state, .launching)
        XCTAssertNil(diagnostic.rendererErrorStatusHex)
        XCTAssertTrue(diagnostic.correlatedEvidence.contains {
            $0.contains("renderer environment failure") &&
                $0.contains("target=WINEDLLPATH") &&
                $0.contains("status=0xC000000D")
        })
        XCTAssertTrue(diagnostic.correlatedEvidence.contains {
            $0.contains("renderer fallback") &&
                $0.contains("result=game-identity-environment") &&
                $0.contains("path=\(executable)")
        })
    }

    func testGameLaunchDiagnosticPreservesRendererFailureBeforeSteamTracksProcess() throws {
        let path = #"G:\SteamLibrary\steamapps\common\Game\game.exe"#
        let processObservation = SteamProcessCreationObservationLog.parseResult(Data((
            "FORGEPLAY_GAME_RENDERER_ERROR_V1\t72011\tchild-environment | " +
                "status=0xC000000D | \(path)\n"
        ).utf8))

        let diagnostic = try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [],
            consoleLines: [],
            processObservation: processObservation,
            now: Date(timeIntervalSince1970: 120)
        ))

        XCTAssertEqual(diagnostic.state, .rendererError)
        XCTAssertNil(diagnostic.appID)
        XCTAssertNil(diagnostic.primaryProcessID)
        XCTAssertTrue(diagnostic.trackedProcessIDs.isEmpty)
        XCTAssertEqual(diagnostic.rendererErrorStage, "child-environment")
        XCTAssertEqual(diagnostic.rendererErrorStatusHex, "0xC000000D")
        XCTAssertEqual(diagnostic.rendererErrorPath, path)
        XCTAssertEqual(diagnostic.processObservationEvidenceState, "complete")
        XCTAssertTrue(diagnostic.correlatedEvidence.contains { $0.contains("emitter-pid=72011") })
    }

    func testGameLaunchDiagnosticDoesNotReviveRendererErrorBeforeLaterRoute() {
        let path = #"G:\SteamLibrary\steamapps\common\Game\game.exe"#
        let processObservation = SteamProcessCreationObservationLog.parseResult(Data((
            "FORGEPLAY_GAME_RENDERER_ERROR_V1\t72013\tchild-environment | " +
                "status=0xC000000D | \(path)\n" +
                "FORGEPLAY_GAME_RENDERER_V1\t72013\trequested=dxmt | applied=dxmt | " +
                "reason=automatic-d3d11-dxmt | evidence=pe32;import=d3d11.dll | \(path)\n"
        ).utf8))

        XCTAssertNil(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [],
            consoleLines: [],
            processObservation: processObservation,
            now: Date(timeIntervalSince1970: 120)
        ))
    }

    func testGameLaunchDiagnosticClassifiesEarlyExitAndCorrelatesRenderer() throws {
        let executable = #"G:\SteamLibrary\steamapps\common\Game\game.exe"#
        let observationData = Data((
            "FORGEPLAY_GAME_RENDERER_V1\t1464\trequested=d3dMetal | applied=d3dMetal | " +
                "reason=automatic-d3d12 | evidence=pe32+;import=d3d12.dll | \(executable)\n"
        ).utf8)
        let processObservation = SteamProcessCreationObservationLog.parseResult(observationData)
        let startedAt = try steamLogDate(year: 2026, month: 7, day: 17, hour: 4, minute: 27, second: 45)
        let diagnostic = try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [
                "[2026-07-17 04:27:45] AppID 900001 adding PID 1464 as a tracked process \"\"\(executable)\"\"",
                "[2026-07-17 04:27:48] AppID 900001 no longer tracking PID 1464, exit code -532262845",
                "[2026-07-17 04:27:48] Remove 900001 from running list"
            ],
            consoleLines: [
                "[2026-07-17 04:27:45] GameAction [AppID 900001, ActionID 1] : LaunchApp changed task to WaitingGameWindow with \"\"",
                "[2026-07-17 04:27:45] GameAction [AppID 900001, ActionID 1] : LaunchApp changed task to Completed with \"\""
            ],
            processObservation: processObservation,
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(20)
        ))

        XCTAssertEqual(diagnostic.state, .earlyExit)
        XCTAssertEqual(diagnostic.appID, "900001")
        XCTAssertEqual(diagnostic.primaryProcessID, 1464)
        XCTAssertEqual(diagnostic.primaryExitCode, -532262845)
        XCTAssertEqual(diagnostic.primaryExitStatusHex, "0xE0465043")
        XCTAssertEqual(diagnostic.executableName, "game.exe")
        XCTAssertNil(diagnostic.rendererApplied)
        XCTAssertEqual(diagnostic.rendererPlannedProfile, "d3dMetal")
        XCTAssertEqual(diagnostic.rendererPlannedComponentOwnership, "d3dMetal")
        XCTAssertEqual(diagnostic.rendererActualLoaded, "unobserved")
        XCTAssertEqual(diagnostic.rendererRoutingReason, "automatic-d3d12")
        XCTAssertEqual(diagnostic.activeProcessIDs, [])
        XCTAssertTrue(diagnostic.summary.contains("3.0 seconds"))
    }

    func testGameLaunchAttemptArtifactCorrelatesHL2RendererFromQuotedCommandLine() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayHL2RendererCorrelation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        let steamLogs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let launchLogs = root.appending(path: "Launch", directoryHint: .isDirectory)
        let observationLog = launchLogs.appending(path: "steam.process-observation.log")
        let gameRunDirectory = launchLogs.appending(
            path: "GameRuns/\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: steamLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchLogs, withIntermediateDirectories: true)
        try Data().write(to: steamLogs.appending(path: "console_log.txt"))

        let executable = #"G:\SteamLibrary\steamapps\common\Half-Life 2\hl2.exe"#
        try (
            "[2026-07-19 02:13:38] AppID 220 adding PID 3080 as a tracked process " +
                "\"\"\(executable)\" -steam -game hl2_complete\"\n" +
                "[2026-07-19 02:13:41] AppID 220 no longer tracking PID 3080, exit code 0\n" +
                "[2026-07-19 02:13:41] Remove 220 from running list\n"
        ).write(
            to: steamLogs.appending(path: "gameprocess_log.txt"),
            atomically: true,
            encoding: .utf8
        )
        try Data((
            "FORGEPLAY_GAME_RENDERER_V1\t3080\trequested=d9vk | applied=legacy32 | " +
                "planned-profile=LEGACY32 | planned-owner=legacy32 | " +
                "planned-components-x64=d9vk,dxmt,dxvk | " +
                "planned-components-x86=d9vk,dxmt,dxvk | actual-loaded=unobserved | " +
                "reason=automatic-legacy32-ambiguous-imports | " +
                "evidence=pe32;no-direct3d-generation | \(executable)\n"
        ).utf8).write(to: observationLog)

        let startedAt = try steamLogDate(
            year: 2026, month: 7, day: 19, hour: 2, minute: 13, second: 38
        )
        let diagnostic = try XCTUnwrap(
            SteamLaunchDiagnosticsReporter().latestGameLaunchDiagnostic(
                in: steamDirectory,
                processObservationLog: observationLog,
                since: startedAt.addingTimeInterval(-1),
                observedAt: startedAt.addingTimeInterval(10),
                persistTo: gameRunDirectory
            )
        )

        XCTAssertEqual(diagnostic.primaryProcessID, 3080)
        XCTAssertEqual(diagnostic.executable, executable)
        XCTAssertEqual(diagnostic.rendererRequested, "d9vk")
        XCTAssertEqual(diagnostic.rendererPlannedProfile, "LEGACY32")
        XCTAssertEqual(
            diagnostic.rendererRoutingReason,
            "automatic-legacy32-ambiguous-imports"
        )

        let attemptURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: gameRunDirectory,
            includingPropertiesForKeys: nil
        ).first {
            $0.lastPathComponent.hasPrefix("game-launch-attempt-") &&
                $0.pathExtension == "json"
        })
        let artifact = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: attemptURL)) as? [String: Any]
        )
        let persistedDiagnostic = try XCTUnwrap(artifact["diagnostic"] as? [String: Any])
        XCTAssertEqual(persistedDiagnostic["executable"] as? String, executable)
        XCTAssertEqual(persistedDiagnostic["rendererRequested"] as? String, "d9vk")
        XCTAssertEqual(persistedDiagnostic["rendererPlannedProfile"] as? String, "LEGACY32")
        XCTAssertEqual(
            persistedDiagnostic["rendererRoutingReason"] as? String,
            "automatic-legacy32-ambiguous-imports"
        )
    }

    func testGameLaunchDiagnosticMonitorStopsWhenManagedPrefixIsInactive() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayDiagnosticMonitor-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let steamDirectory = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        let processObservationLog = root.appending(
            path: "steam.process-observation.log"
        )
        try FileManager.default.createDirectory(
            at: steamDirectory.appending(path: "logs", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data().write(to: processObservationLog)

        let inactivityProbe = ManagedPrefixInactivityProbe()
        let manager = SteamManager(
            pathManager: PathManager(),
            runner: makeCuratedRuntimeRunner(),
            compatibilityPrefixExitWaiter: { observedPrefix, _, _ in
                inactivityProbe.record(observedPrefix)
                return true
            }
        )
        manager.ensureGameLaunchDiagnosticMonitoring(
            managedPrefix: prefix,
            in: steamDirectory,
            processObservationLog: processObservationLog,
            since: Date()
        )

        for _ in 0..<100 where inactivityProbe.paths.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(inactivityProbe.paths, [prefix.standardizedFileURL.path])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(inactivityProbe.paths.count, 1)
    }

    func testGameLaunchDiagnosticMatchesFollowupPIDByFullPathNotBasename() throws {
        let launcher = #"G:\SteamLibrary\steamapps\common\Game\launcher.exe"#
        let game = #"G:\SteamLibrary\steamapps\common\Game\bin\game.exe"#
        let sameBasenameElsewhere = #"H:\AnotherLibrary\steamapps\common\Game\bin\game.exe"#
        let processObservation = SteamProcessCreationObservationLog.parseResult(Data((
            "FORGEPLAY_GAME_RENDERER_V1\t3091\trequested=dxmt | applied=dxmt | " +
                "reason=automatic-d3d11-dxmt | evidence=pe32;import=d3d11.dll | \(game)\n" +
                "FORGEPLAY_GAME_RENDERER_V1\t3091\trequested=d3dMetal | applied=d3dMetal | " +
                "reason=wrong-same-basename-route | evidence=pe32+;import=d3d12.dll | " +
                "\(sameBasenameElsewhere)\n"
        ).utf8))
        let startedAt = try steamLogDate(
            year: 2026, month: 7, day: 19, hour: 2, minute: 14, second: 0
        )

        let diagnostic = try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [
                "[2026-07-19 02:14:00] AppID 221 adding PID 3090 as a tracked process " +
                    "\"\"\(launcher)\" -steam\"",
                "[2026-07-19 02:14:01] AppID 221 adding PID 3091 as a tracked process " +
                    "\"\"\(game)\" -steam -game sample\""
            ],
            consoleLines: [],
            processObservation: processObservation,
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(5)
        ))

        XCTAssertEqual(diagnostic.primaryProcessID, 3091)
        XCTAssertEqual(diagnostic.executable, game)
        XCTAssertEqual(diagnostic.rendererPlannedProfile, "dxmt")
        XCTAssertEqual(diagnostic.rendererRoutingReason, "automatic-d3d11-dxmt")
        XCTAssertFalse(diagnostic.correlatedEvidence.contains {
            $0.contains("wrong-same-basename-route")
        })
    }

    func testGameLaunchDiagnosticCorrelatesStellarBladeOuterQuotedCommand() throws {
        let executable = #"G:\Steam Library\steamapps\common\Stellar Blade Demo\SB.exe"#
        let processObservation = SteamProcessCreationObservationLog.parseResult(Data((
            "FORGEPLAY_GAME_RENDERER_V1\t3100\trequested=d3dMetal | applied=d3dMetal | " +
                "reason=automatic-d3d12 | evidence=pe32+;import=d3d12.dll | \(executable)\n"
        ).utf8))
        let startedAt = try steamLogDate(
            year: 2026, month: 7, day: 19, hour: 2, minute: 15, second: 0
        )

        let diagnostic = try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [
                "[2026-07-19 02:15:00] AppID 3564860 adding PID 3100 as a tracked process " +
                    "\"\(executable) -DistributionPlatform=Steam\""
            ],
            consoleLines: [],
            processObservation: processObservation,
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(5)
        ))

        XCTAssertEqual(diagnostic.primaryProcessID, 3100)
        XCTAssertEqual(diagnostic.executable, executable)
        XCTAssertEqual(diagnostic.rendererPlannedProfile, "d3dMetal")
        XCTAssertEqual(diagnostic.rendererRoutingReason, "automatic-d3d12")
        XCTAssertEqual(diagnostic.rendererRoutingEvidence, "pe32+;import=d3d12.dll")

        let diagnosticWithoutRenderer = try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [
                "[2026-07-19 02:15:00] AppID 3564860 adding PID 3100 as a tracked process " +
                    "\"\(executable) -DistributionPlatform=Steam\""
            ],
            consoleLines: [],
            processObservation: SteamProcessCreationObservationLog.parseResult(Data()),
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(5)
        ))
        XCTAssertEqual(diagnosticWithoutRenderer.executable, executable)
    }

    func testWineCrashEvidenceCorrelatesRepeatedExceptionWithoutCrossContamination() throws {
        let crashObservations = WineRuntimeCrashEventParser.parse(
            stdoutLines: [
                "WineDbg attached to pid 08b8",
                "Unhandled exception: 0xe0465043 in 64-bit code (0x006fffff33d8c7).",
                "Backtrace:",
                "=>0 0x006fffff33d8c7 in kernelbase (+0xd8c7) (0x0000000031fea0)",
                "  1 0x000001400014bc in compatibility_sample (+0x14bc) (0x0000000031fea0)",
                "Modules:",
                "System information:",
                "Wine build: wine-11.12",
                "Host system: Darwin"
            ],
            stderrLines: [
                "wine: Unhandled exception 0xe0465043 in thread 88c at address " +
                    "00006FFFFF33D8C7 (thread 088c), starting debugger...",
                "088c:err:seh:start_debugger Couldn't start debugger L\"false\" (2)",
                "wine: Unhandled exception 0xe0465043 in thread 8bc at address " +
                    "00006FFFFF33D8C7 (thread 08bc), starting debugger..."
            ]
        )

        XCTAssertEqual(crashObservations.count, 2)
        XCTAssertEqual(crashObservations[0].threadIDHex, "0x088C")
        XCTAssertEqual(crashObservations[0].automaticBacktraceState, .debuggerStartFailed)
        XCTAssertEqual(crashObservations[1].threadIDHex, "0x08BC")
        XCTAssertEqual(crashObservations[1].debuggerProcessID, 2232)
        XCTAssertEqual(crashObservations[1].automaticBacktraceState, .captured)
        XCTAssertEqual(crashObservations[1].backtraceFrames.count, 2)

        let startedAt = try steamLogDate(
            year: 2026, month: 7, day: 18, hour: 19, minute: 30, second: 23
        )
        let diagnostics = SteamGameLaunchDiagnosticAnalyzer.analyzeAttempts(
            gameProcessLines: [
                #"[2026-07-18 19:30:23] AppID 900001 adding PID 2184 as a tracked process ""G:\SteamLibrary\steamapps\common\Compatibility Sample\compatibility_sample.exe"""#,
                "[2026-07-18 19:30:31] AppID 900001 no longer tracking PID 2184, exit code -532262845",
                "[2026-07-18 19:30:31] Remove 900001 from running list",
                #"[2026-07-18 19:30:46] AppID 900001 adding PID 2232 as a tracked process ""G:\SteamLibrary\steamapps\common\Compatibility Sample\compatibility_sample.exe"""#,
                "[2026-07-18 19:30:50] AppID 900001 no longer tracking PID 2232, exit code -532262845",
                "[2026-07-18 19:30:50] Remove 900001 from running list"
            ],
            consoleLines: [],
            processObservation: SteamProcessCreationObservationLog.parseResult(Data()),
            runtimeCrashObservations: crashObservations,
            runtimeCrashStdoutEvidenceState: SteamEvidenceReadState.captured.rawValue,
            runtimeCrashStderrEvidenceState: SteamEvidenceReadState.captured.rawValue,
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(40)
        )

        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertEqual(diagnostics[0].runtimeCrashEvents.first?.threadIDHex, "0x088C")
        XCTAssertEqual(
            diagnostics[0].runtimeCrashEvents.first?.correlationBasis,
            "matchingExitStatusAndReverseSourceOrder"
        )
        XCTAssertEqual(diagnostics[1].runtimeCrashEvents.first?.windowsProcessID, 2232)
        XCTAssertEqual(
            diagnostics[1].runtimeCrashEvents.first?.correlationBasis,
            "windowsProcessIDAndExitStatus"
        )
        XCTAssertTrue(diagnostics[1].summary.contains("Automatic Wine backtrace captured"))
    }

    func testGameLaunchDiagnosticDoesNotInferHeadlessStateFromSteamTaskText() throws {
        let executable = #"G:\SteamLibrary\steamapps\common\Game\game.exe"#
        let processObservation = SteamProcessCreationObservationLog.parseResult(Data((
            "FORGEPLAY_GAME_RENDERER_V1\t1548\trequested=d3dMetal | applied=d3dMetal | " +
                "reason=automatic-d3d12 | evidence=pe32+;import=d3d12.dll | \(executable)\n"
        ).utf8))
        let startedAt = try steamLogDate(year: 2026, month: 7, day: 17, hour: 4, minute: 30, second: 0)
        let diagnostic = try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [
                "[2026-07-17 04:30:00] AppID 777 adding PID 1548 as a tracked process \"\"\(executable)\"\""
            ],
            consoleLines: [
                "[2026-07-17 04:30:00] GameAction [AppID 777, ActionID 1] : LaunchApp changed task to WaitingGameWindow with \"\""
            ],
            processObservation: processObservation,
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(30),
            launchStabilityThreshold: 15
        ))

        XCTAssertEqual(diagnostic.state, .running)
        XCTAssertEqual(diagnostic.activeProcessIDs, [1548])
        XCTAssertNil(diagnostic.endedAt)
        XCTAssertEqual(diagnostic.consoleLastTask, "WaitingGameWindow")
        XCTAssertTrue(diagnostic.summary.contains("window state is not available"))

        let completedDiagnostic = try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [
                "[2026-07-17 04:30:00] AppID 777 adding PID 1548 as a tracked process \"\"\(executable)\"\""
            ],
            consoleLines: [
                "[2026-07-17 04:30:00] GameAction [AppID 777, ActionID 1] : LaunchApp changed task to WaitingGameWindow with \"\"",
                "[2026-07-17 04:30:01] GameAction [AppID 777, ActionID 1] : LaunchApp changed task to Completed with \"\""
            ],
            processObservation: processObservation,
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(30),
            launchStabilityThreshold: 15
        ))
        XCTAssertEqual(completedDiagnostic.state, .running)
    }

    func testGameLaunchDiagnosticUsesSourceOrderForRelaunchesWithinSameSecond() throws {
        let firstExecutable = #"G:\SteamLibrary\steamapps\common\Game\first.exe"#
        let secondExecutable = #"G:\SteamLibrary\steamapps\common\Game\second.exe"#
        let startedAt = try steamLogDate(
            year: 2026, month: 7, day: 17, hour: 4, minute: 59, second: 0
        )
        let diagnostic = try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [
                "[2026-07-17 04:59:00] AppID 777 adding PID 1400 as a tracked process \"\"\(firstExecutable)\"\"",
                "[2026-07-17 04:59:00] AppID 777 no longer tracking PID 1400, exit code 1",
                "[2026-07-17 04:59:00] Remove 777 from running list",
                "[2026-07-17 04:59:00] AppID 777 adding PID 1401 as a tracked process \"\"\(secondExecutable)\"\""
            ],
            consoleLines: [],
            processObservation: SteamProcessCreationObservationLog.parseResult(Data()),
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(5)
        ))

        XCTAssertEqual(diagnostic.state, .launching)
        XCTAssertEqual(diagnostic.primaryProcessID, 1401)
        XCTAssertTrue(diagnostic.executable?.contains("second.exe") == true)
        XCTAssertNil(diagnostic.primaryExitCode)
    }

    func testGameLaunchDiagnosticTreatsGoingAwayAsUnknownExitTermination() throws {
        let executable = #"G:\SteamLibrary\steamapps\common\Game\game.exe"#
        let startedAt = try steamLogDate(year: 2026, month: 7, day: 17, hour: 5, minute: 0, second: 0)
        let diagnostic = try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [
                "[2026-07-17 05:00:00] AppID 777 adding PID 1360 as a tracked process \"\"\(executable)\"\"",
                "[2026-07-17 05:00:20] Game 777 going away; no longer tracking PID 1360"
            ],
            consoleLines: [],
            processObservation: SteamProcessCreationObservationLog.parseResult(Data()),
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(30)
        ))

        XCTAssertEqual(diagnostic.state, .exited)
        XCTAssertEqual(diagnostic.activeProcessIDs, [])
        XCTAssertEqual(diagnostic.endedAt, startedAt.addingTimeInterval(20))
        XCTAssertNil(diagnostic.primaryExitCode)
        XCTAssertTrue(diagnostic.exitCodesByProcessID.isEmpty)
    }

    func testGameLaunchDiagnosticUsesLatestOrderedRendererEventForAttempt() throws {
        let executable = #"G:\SteamLibrary\steamapps\common\Game\game.exe"#
        let observation = SteamProcessCreationObservationLog.parseResult(Data((
            "FORGEPLAY_GAME_RENDERER_ERROR_V1\t1600\tchild-environment | status=0xC0000135 | \(executable)\n" +
                "FORGEPLAY_GAME_RENDERER_V1\t1600\trequested=d3dMetal | applied=d3dMetal | " +
                "reason=automatic-d3d12 | evidence=pe32+;import=d3d12.dll | \(executable)\n" +
                "FORGEPLAY_GAME_RENDERER_ERROR_V1\t9999\tchild-environment | status=0xC0000005 | " +
                #"H:\AnotherLibrary\steamapps\common\Game\game.exe"# + "\n"
        ).utf8))
        let startedAt = try steamLogDate(year: 2026, month: 7, day: 17, hour: 5, minute: 1, second: 0)
        let diagnostic = try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [
                "[2026-07-17 05:01:00] AppID 888 adding PID 1600 as a tracked process \"\"\(executable)\"\""
            ],
            consoleLines: [],
            processObservation: observation,
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(2)
        ))

        XCTAssertEqual(observation.gameRendererErrors.first?.recordSequence, 0)
        XCTAssertEqual(observation.gameRendererObservations.first?.recordSequence, 1)
        XCTAssertEqual(diagnostic.state, .launching)
        XCTAssertNil(diagnostic.rendererApplied)
        XCTAssertEqual(diagnostic.rendererPlannedProfile, "d3dMetal")
        XCTAssertEqual(diagnostic.rendererActualLoaded, "unobserved")
        XCTAssertNil(diagnostic.rendererErrorStatusHex)
    }

    func testRendererLoadV3VerifiedPathPromotesOnlyVerifiedModuleToSuccessfulLoad() throws {
        let executable = #"G:\SteamLibrary\steamapps\common\VerifiedGame\game.exe"#
        let actualPath = #"Z:\ForgePlay\Renderers\DXMT\x86_64-windows\d3d11.dll"#
        let processObservation = SteamProcessCreationObservationLog.parseResult(Data((
            "FORGEPLAY_GAME_RENDERER_ROUTE_V2\t72101\trequested=dxmt | applied=dxmt | " +
                "planned-profile=DXMT | planned-owner=dxmt | " +
                "planned-components-x64=d3d11,dxgi | planned-components-x86=d3d11,dxgi | " +
                "actual-loaded=unobserved | reason=automatic-d3d11-dxmt | " +
                "evidence=pe32;import=d3d11.dll | correlation=load-v3-verified | " +
                "\(executable)\n" +
                "FORGEPLAY_GAME_RENDERER_LOAD_V3\t72101\tstate=loaded | module=d3d11.dll | " +
                "actual-path=\(actualPath) | path-owner=verified | profile=DXMT | " +
                "owner=dxmt | status=0x00000000 | correlation=load-v3-verified | " +
                "executable=\(executable)\n"
        ).utf8))

        let load = try XCTUnwrap(processObservation.gameRendererModuleLoads.first)
        XCTAssertEqual(processObservation.gameRendererModuleLoads.count, 1)
        XCTAssertEqual(load.state, .loaded)
        XCTAssertEqual(load.pathOwnership, .verified)
        XCTAssertEqual(load.actualPath, actualPath)

        let diagnostic = try rendererDiagnostic(
            processObservation: processObservation,
            executable: executable,
            processID: 72_101
        )

        XCTAssertEqual(diagnostic.rendererActualLoaded, "loaded")
        XCTAssertEqual(diagnostic.rendererLoadedModules, ["d3d11.dll"])
        XCTAssertEqual(diagnostic.rendererLoadedModulePaths, [actualPath])
        XCTAssertNil(diagnostic.rendererModuleLoadFailures)
    }

    func testRendererLoadV3UnverifiedPathOwnershipNeverEntersSuccessfulModuleArrays() throws {
        let cases: [(
            processID: Int32,
            pathOwnership: SteamGameRendererLoadPathOwnership,
            actualPath: String,
            correlation: String
        )] = [
            (
                72_102,
                .mismatch,
                #"Z:\UnexpectedRenderer\d3d11.dll"#,
                "load-v3-mismatch"
            ),
            (
                72_103,
                .unavailable,
                #"Z:\UnverifiedRenderer\d3d11.dll"#,
                "load-v3-unavailable"
            )
        ]

        for testCase in cases {
            let executable =
                #"G:\SteamLibrary\steamapps\common\UnverifiedGame\game.exe"#
            let processObservation = SteamProcessCreationObservationLog.parseResult(Data((
                "FORGEPLAY_GAME_RENDERER_ROUTE_V2\t\(testCase.processID)\t" +
                    "requested=dxmt | applied=dxmt | planned-profile=DXMT | " +
                    "planned-owner=dxmt | planned-components-x64=d3d11,dxgi | " +
                    "planned-components-x86=d3d11,dxgi | actual-loaded=unobserved | " +
                    "reason=automatic-d3d11-dxmt | evidence=pe32;no-direct3d-generation | " +
                    "correlation=\(testCase.correlation) | \(executable)\n" +
                    "FORGEPLAY_GAME_RENDERER_LOAD_V3\t\(testCase.processID)\t" +
                    "state=loaded | module=d3d11.dll | actual-path=\(testCase.actualPath) | " +
                    "path-owner=\(testCase.pathOwnership.rawValue) | profile=DXMT | " +
                    "owner=dxmt | status=0x00000000 | " +
                    "correlation=\(testCase.correlation) | executable=\(executable)\n"
            ).utf8))

            let load = try XCTUnwrap(processObservation.gameRendererModuleLoads.first)
            XCTAssertEqual(processObservation.gameRendererModuleLoads.count, 1)
            XCTAssertEqual(load.state, .loaded)
            XCTAssertEqual(load.pathOwnership, testCase.pathOwnership)

            let diagnostic = try rendererDiagnostic(
                processObservation: processObservation,
                executable: executable,
                processID: testCase.processID
            )

            XCTAssertEqual(diagnostic.rendererActualLoaded, "load-path-unverified")
            XCTAssertNil(diagnostic.rendererLoadedModules)
            XCTAssertNil(diagnostic.rendererLoadedModulePaths)
            XCTAssertEqual(
                diagnostic.rendererModuleLoadFailures,
                [
                    "d3d11.dll=load-path-\(testCase.pathOwnership.rawValue):" +
                        testCase.actualPath
                ]
            )
        }
    }

    func testLegacyRendererLoadV2RemainsRawEvidenceWithoutSuccessfulLoadProof() throws {
        let executable = #"G:\SteamLibrary\steamapps\common\LegacyEvidence\game.exe"#
        let actualPath = #"Z:\HistoricalRenderer\d3d11.dll"#
        let processObservation = SteamProcessCreationObservationLog.parseResult(Data((
            "FORGEPLAY_GAME_RENDERER_ROUTE_V2\t72104\trequested=dxmt | applied=dxmt | " +
                "planned-profile=DXMT | planned-owner=dxmt | " +
                "planned-components-x64=d3d11,dxgi | planned-components-x86=d3d11,dxgi | " +
                "actual-loaded=unobserved | reason=automatic-d3d11-dxmt | " +
                "evidence=pe32;no-direct3d-generation | correlation=legacy-load-v2 | " +
                "\(executable)\n" +
                "FORGEPLAY_GAME_RENDERER_LOAD_V2\t72104\tstate=loaded | module=d3d11.dll | " +
                "actual-path=\(actualPath) | profile=DXMT | owner=dxmt | " +
                "status=0x00000000 | correlation=legacy-load-v2 | " +
                "executable=\(executable)\n"
        ).utf8))

        let load = try XCTUnwrap(processObservation.gameRendererModuleLoads.first)
        XCTAssertEqual(processObservation.gameRendererModuleLoads.count, 1)
        XCTAssertEqual(load.state, .loaded)
        XCTAssertEqual(load.pathOwnership, .legacyUnverified)
        XCTAssertEqual(load.actualPath, actualPath)

        let diagnostic = try rendererDiagnostic(
            processObservation: processObservation,
            executable: executable,
            processID: 72_104
        )

        XCTAssertEqual(diagnostic.rendererActualLoaded, "load-path-unverified")
        XCTAssertNil(diagnostic.rendererLoadedModules)
        XCTAssertNil(diagnostic.rendererLoadedModulePaths)
        XCTAssertEqual(
            diagnostic.rendererModuleLoadFailures,
            ["d3d11.dll=load-path-legacy-unverified:\(actualPath)"]
        )
    }

    func testCanonicalRendererEventPrefersSpecificImportOverLaterAmbiguousRoute() throws {
        let executable = #"G:\SteamLibrary\steamapps\common\RankedRoutes\game.exe"#
        let processObservation = SteamProcessCreationObservationLog.parseResult(Data((
            "FORGEPLAY_GAME_RENDERER_ROUTE_V2\t72105\trequested=dxmt | applied=dxmt | " +
                "planned-profile=DXMT | planned-owner=dxmt | " +
                "planned-components-x64=d3d11,dxgi | planned-components-x86=d3d11,dxgi | " +
                "actual-loaded=unobserved | reason=specific-dxgi-route | " +
                "evidence=pe32;import=dxgi.dll | correlation=specific-route | " +
                "\(executable)\n" +
                "FORGEPLAY_GAME_RENDERER_ROUTE_V2\t72105\trequested=d9vk | applied=d9vk | " +
                "planned-profile=D9VK | planned-owner=d9vk | " +
                "planned-components-x64=d3d8,d3d9 | planned-components-x86=d3d8,d3d9 | " +
                "actual-loaded=unobserved | reason=later-ambiguous-route | " +
                "evidence=pe32;no-direct3d-generation | correlation=ambiguous-route | " +
                "\(executable)\n"
        ).utf8))

        let diagnostic = try rendererDiagnostic(
            processObservation: processObservation,
            executable: executable,
            processID: 72_105
        )

        XCTAssertEqual(diagnostic.rendererPlannedProfile, "DXMT")
        XCTAssertEqual(diagnostic.rendererPlannedComponentOwnership, "dxmt")
        XCTAssertEqual(diagnostic.rendererRoutingReason, "specific-dxgi-route")
        XCTAssertEqual(diagnostic.rendererRoutingEvidence, "pe32;import=dxgi.dll")
    }

    func testCanonicalRendererEventTreatsVerifiedActualLoadAsHighestEvidence() throws {
        let executable = #"G:\SteamLibrary\steamapps\common\VerifiedRank\game.exe"#
        let actualPath = #"Z:\ForgePlay\Renderers\DXVK\x86_64-windows\dxgi.dll"#
        let processObservation = SteamProcessCreationObservationLog.parseResult(Data((
            "FORGEPLAY_GAME_RENDERER_ROUTE_V2\t72106\trequested=dxmt | applied=dxmt | " +
                "planned-profile=DXMT | planned-owner=dxmt | " +
                "planned-components-x64=d3d11,dxgi | planned-components-x86=d3d11,dxgi | " +
                "actual-loaded=unobserved | reason=specific-d3d11-route | " +
                "evidence=pe32;import=d3d11.dll | correlation=specific-d3d11 | " +
                "\(executable)\n" +
                "FORGEPLAY_GAME_RENDERER_ROUTE_V2\t72106\trequested=vulkan | applied=dxvk | " +
                "planned-profile=DXVK | planned-owner=dxvk | " +
                "planned-components-x64=d3d10,d3d11,dxgi | " +
                "planned-components-x86=d3d10,d3d11,dxgi | actual-loaded=unobserved | " +
                "reason=verified-actual-route | evidence=pe32;no-direct3d-generation | " +
                "correlation=verified-actual | \(executable)\n" +
                "FORGEPLAY_GAME_RENDERER_LOAD_V3\t72106\tstate=loaded | module=dxgi.dll | " +
                "actual-path=\(actualPath) | path-owner=verified | profile=DXVK | " +
                "owner=dxvk | status=0x00000000 | correlation=verified-actual | " +
                "executable=\(executable)\n" +
                "FORGEPLAY_GAME_RENDERER_ROUTE_V2\t72106\trequested=d9vk | applied=d9vk | " +
                "planned-profile=D9VK | planned-owner=d9vk | " +
                "planned-components-x64=d3d8,d3d9 | planned-components-x86=d3d8,d3d9 | " +
                "actual-loaded=unobserved | reason=latest-ambiguous-route | " +
                "evidence=pe32;no-direct3d-generation | correlation=latest-ambiguous | " +
                "\(executable)\n"
        ).utf8))

        let diagnostic = try rendererDiagnostic(
            processObservation: processObservation,
            executable: executable,
            processID: 72_106
        )

        XCTAssertEqual(diagnostic.rendererPlannedProfile, "DXVK")
        XCTAssertEqual(diagnostic.rendererPlannedComponentOwnership, "dxvk")
        XCTAssertEqual(diagnostic.rendererActualLoaded, "loaded")
        XCTAssertEqual(diagnostic.rendererLoadedModules, ["dxgi.dll"])
        XCTAssertEqual(diagnostic.rendererLoadedModulePaths, [actualPath])
        XCTAssertEqual(diagnostic.rendererRoutingReason, "verified-actual-route")
    }

    func testCanonicalRendererEventPrefersErrorAtSameRankAndPairedSequence() throws {
        let executable = #"G:\SteamLibrary\steamapps\common\TiedEvidence\game.exe"#
        let rejectedPath = #"Z:\UnexpectedRenderer\d3d11.dll"#
        let processObservation = SteamProcessCreationObservationLog.parseResult(Data((
            "FORGEPLAY_GAME_RENDERER_ERROR_V1\t72107\tmodule-load | " +
                "status=0xC0000135 | \(rejectedPath)\n" +
                "FORGEPLAY_GAME_RENDERER_ROUTE_V2\t72107\trequested=dxmt | " +
                "applied=dxmt | planned-profile=DXMT | planned-owner=dxmt | " +
                "planned-components-x64=d3d11,dxgi | planned-components-x86=d3d11,dxgi | " +
                "actual-loaded=unobserved | reason=ambiguous-rejected-route | " +
                "evidence=pe32;no-direct3d-generation | correlation=tied-sequence | " +
                "\(executable)\n" +
                "FORGEPLAY_GAME_RENDERER_LOAD_V3\t72107\tstate=loaded | module=d3d11.dll | " +
                "actual-path=\(rejectedPath) | path-owner=mismatch | profile=DXMT | " +
                "owner=dxmt | status=0x00000000 | correlation=tied-sequence | " +
                "executable=\(executable)\n"
        ).utf8))

        XCTAssertEqual(processObservation.gameRendererErrors.first?.recordSequence, 0)
        XCTAssertEqual(processObservation.gameRendererObservations.first?.recordSequence, 1)
        XCTAssertEqual(processObservation.gameRendererModuleLoads.first?.recordSequence, 2)

        let diagnostic = try rendererDiagnostic(
            processObservation: processObservation,
            executable: executable,
            processID: 72_107
        )

        XCTAssertEqual(diagnostic.state, .rendererError)
        XCTAssertEqual(diagnostic.rendererErrorStage, "module-load")
        XCTAssertEqual(diagnostic.rendererErrorStatusHex, "0xC0000135")
        XCTAssertEqual(diagnostic.rendererErrorPath, rejectedPath)
        XCTAssertNil(diagnostic.rendererPlannedProfile)
        XCTAssertNil(diagnostic.rendererActualLoaded)
        XCTAssertNil(diagnostic.rendererLoadedModules)
    }

    func testGameLaunchDiagnosticDoesNotReusePriorAttemptRendererErrorWithSamePath() throws {
        let executable = #"G:\SteamLibrary\steamapps\common\Game\game.exe"#
        let errorRecord = "FORGEPLAY_GAME_RENDERER_ERROR_V1\t1500\tchild-environment | " +
            "status=0xC0000135 | \(executable)\n"
        let observation = SteamProcessCreationObservationLog.parseResult(Data(errorRecord.utf8))
        let startedAt = try steamLogDate(
            year: 2026, month: 7, day: 17, hour: 5, minute: 1, second: 30
        )
        let diagnostic = try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [
                "[2026-07-17 05:01:30] AppID 888 adding PID 1600 as a tracked process \"\"\(executable)\"\""
            ],
            consoleLines: [],
            processObservation: observation,
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(2)
        ))

        XCTAssertEqual(diagnostic.state, .launching)
        XCTAssertNil(diagnostic.rendererErrorStatusHex)
    }

    func testGameLaunchDiagnosticSeparatesAuxiliaryFailureFromPrimaryResult() throws {
        let game = #"G:\SteamLibrary\steamapps\common\Game\game.exe"#
        let helper = #"G:\SteamLibrary\steamapps\common\Game\helper.exe"#
        let startedAt = try steamLogDate(year: 2026, month: 7, day: 17, hour: 5, minute: 2, second: 0)
        let diagnostic = try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [
                "[2026-07-17 05:02:00] AppID 999 adding PID 1700 as a tracked process \"\"\(game)\"\"",
                "[2026-07-17 05:02:01] AppID 999 adding PID 1701 as a tracked process \"\"\(helper)\"\"",
                "[2026-07-17 05:02:20] AppID 999 no longer tracking PID 1700, exit code 0",
                "[2026-07-17 05:02:21] AppID 999 no longer tracking PID 1701, exit code 5"
            ],
            consoleLines: [],
            processObservation: SteamProcessCreationObservationLog.parseResult(Data()),
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(30)
        ))

        XCTAssertEqual(diagnostic.state, .exitedWithError)
        XCTAssertEqual(diagnostic.primaryProcessID, 1700)
        XCTAssertEqual(diagnostic.primaryExitCode, 0)
        XCTAssertEqual(diagnostic.failureProcessID, 1701)
        XCTAssertEqual(diagnostic.failureExitCode, 5)
        XCTAssertEqual(diagnostic.failureExitStatusHex, "0x00000005")
        XCTAssertEqual(diagnostic.exitCodesByProcessID["1701"], 5)
    }

    func testGameLaunchDiagnosticPersistsOnlyMaterialStateChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayGameDiagnostic-\(UUID().uuidString)", directoryHint: .isDirectory)
        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        let steamLogs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let launchLogs = root.appending(path: "Launch", directoryHint: .isDirectory)
        let observationLog = launchLogs.appending(path: "steam.process-observation.log")
        let runIdentifier = UUID().uuidString
        let gameRunDirectory = launchLogs.appending(
            path: "GameRuns/\(runIdentifier)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: steamLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchLogs, withIntermediateDirectories: true)
        let executable = #"G:\SteamLibrary\steamapps\common\Game\game.exe"#
        try "[2026-07-17 05:03:00] AppID 123 adding PID 1800 as a tracked process \"\"\(executable)\"\"\n"
            .write(to: steamLogs.appending(path: "gameprocess_log.txt"), atomically: true, encoding: .utf8)
        try "".write(to: steamLogs.appending(path: "console_log.txt"), atomically: true, encoding: .utf8)
        try Data("\n".utf8).write(to: observationLog)
        let reporter = SteamLaunchDiagnosticsReporter()
        let startedAt = try steamLogDate(year: 2026, month: 7, day: 17, hour: 5, minute: 3, second: 0)

        let first = try XCTUnwrap(reporter.latestGameLaunchDiagnostic(
            in: steamDirectory,
            processObservationLog: observationLog,
            since: startedAt.addingTimeInterval(-1),
            observedAt: startedAt.addingTimeInterval(30),
            persistTo: gameRunDirectory
        ))
        let diagnosticURL = gameRunDirectory.appending(path: "game-launch-diagnostic.json")
        let firstData = try Data(contentsOf: diagnosticURL)
        let second = try XCTUnwrap(reporter.latestGameLaunchDiagnostic(
            in: steamDirectory,
            processObservationLog: observationLog,
            since: startedAt.addingTimeInterval(-1),
            observedAt: startedAt.addingTimeInterval(60),
            persistTo: gameRunDirectory
        ))
        let secondData = try Data(contentsOf: diagnosticURL)

        XCTAssertEqual(first.state, .running)
        XCTAssertEqual(second.state, .running)
        XCTAssertEqual(second.structuredLogState, "captured")
        XCTAssertEqual(firstData, secondData)

        let supportSnapshot = try XCTUnwrap(reporter.latestGameLaunchDiagnostic(
            in: steamDirectory,
            processObservationLog: observationLog,
            since: startedAt.addingTimeInterval(-1),
            observedAt: startedAt.addingTimeInterval(90),
            persistTo: gameRunDirectory,
            forceCurrentSnapshot: true
        ))
        let supportSnapshotData = try Data(contentsOf: diagnosticURL)
        XCTAssertEqual(try XCTUnwrap(supportSnapshot.elapsedSeconds), 90, accuracy: 0.001)
        XCTAssertNotEqual(secondData, supportSnapshotData)

        try (
            "[2026-07-17 05:03:00] AppID 123 adding PID 1800 as a tracked process \"\"\(executable)\"\"\n" +
                "[2026-07-17 05:04:30] Game 123 going away; no longer tracking PID 1800\n"
        ).write(to: steamLogs.appending(path: "gameprocess_log.txt"), atomically: true, encoding: .utf8)
        let terminal = try XCTUnwrap(reporter.latestGameLaunchDiagnostic(
            in: steamDirectory,
            processObservationLog: observationLog,
            since: startedAt.addingTimeInterval(-1),
            observedAt: startedAt.addingTimeInterval(100),
            persistTo: gameRunDirectory
        ))
        let terminalData = try Data(contentsOf: diagnosticURL)

        XCTAssertEqual(terminal.state, .exited)
        XCTAssertNotEqual(secondData, terminalData)
    }

    func testGameLaunchDiagnosticPersistsNoAttemptCaptureEnvelope() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayNoAttemptCapture-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        let steamLogs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let launchLogs = root.appending(path: "Launch", directoryHint: .isDirectory)
        let observationLog = launchLogs.appending(path: "steam.process-observation.log")
        let stdoutLog = launchLogs.appending(path: "steam_stdout.log")
        let stderrLog = launchLogs.appending(path: "steam_stderr.log")
        let runIdentifier = UUID().uuidString
        let gameRunDirectory = launchLogs.appending(
            path: "GameRuns/\(runIdentifier)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: steamLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchLogs, withIntermediateDirectories: true)
        for file in [
            steamLogs.appending(path: "gameprocess_log.txt"),
            steamLogs.appending(path: "console_log.txt"),
            observationLog,
            stdoutLog,
            stderrLog,
        ] {
            try Data().write(to: file)
        }

        let diagnostic = SteamLaunchDiagnosticsReporter().latestGameLaunchDiagnostic(
            in: steamDirectory,
            processObservationLog: observationLog,
            launchStdoutLog: stdoutLog,
            launchStderrLog: stderrLog,
            since: Date(timeIntervalSince1970: 100),
            observedAt: Date(timeIntervalSince1970: 120),
            persistTo: gameRunDirectory,
            forceCurrentSnapshot: true
        )

        XCTAssertNil(diagnostic)
        let captureData = try Data(
            contentsOf: gameRunDirectory.appending(path: "game-launch-capture.json")
        )
        let capture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: captureData) as? [String: Any]
        )
        XCTAssertEqual((capture["schema_version"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(capture["run_identifier"] as? String, runIdentifier.lowercased())
        XCTAssertEqual(capture["capture_state"] as? String, "noTrackedGameProcess")
        XCTAssertEqual(capture["reason_code"] as? String, "steamGameProcessNotObserved")
        XCTAssertEqual((capture["attempt_count"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((capture["steam_tracked_attempt_count"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((capture["inputs"] as? [[String: Any]])?.count, 5)
    }

    func testGameLaunchDiagnosticPersistsRendererFailureWithoutSteamAttempt() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRendererSetupFailure-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        let steamLogs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let launchLogs = root.appending(path: "Launch", directoryHint: .isDirectory)
        let observationLog = launchLogs.appending(path: "steam.process-observation.log")
        let gameRunDirectory = launchLogs.appending(
            path: "GameRuns/\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let executable = #"G:\SteamLibrary\steamapps\common\Game\game.exe"#
        try FileManager.default.createDirectory(at: steamLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchLogs, withIntermediateDirectories: true)
        try Data().write(to: steamLogs.appending(path: "gameprocess_log.txt"))
        try Data().write(to: steamLogs.appending(path: "console_log.txt"))
        try Data((
            "FORGEPLAY_GAME_RENDERER_ERROR_V1\t72012\tchild-environment | " +
                "status=0xC000000D | \(executable)\n"
        ).utf8).write(to: observationLog)

        let diagnostic = try XCTUnwrap(
            SteamLaunchDiagnosticsReporter().latestGameLaunchDiagnostic(
                in: steamDirectory,
                processObservationLog: observationLog,
                since: Date(timeIntervalSince1970: 100),
                observedAt: Date(timeIntervalSince1970: 120),
                persistTo: gameRunDirectory,
                forceCurrentSnapshot: true
            )
        )

        XCTAssertEqual(diagnostic.state, .rendererError)
        XCTAssertEqual(diagnostic.structuredLogState, "captured")
        XCTAssertTrue(FileSystemItemPolicy.isRegularNonSymlinkFile(
            gameRunDirectory.appending(path: "game-launch-diagnostic.json")
        ))
        let captureData = try Data(
            contentsOf: gameRunDirectory.appending(path: "game-launch-capture.json")
        )
        let capture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: captureData) as? [String: Any]
        )
        XCTAssertEqual(capture["capture_state"] as? String, "rendererSetupFailureCaptured")
        XCTAssertEqual(
            capture["reason_code"] as? String,
            "rendererSetupFailedBeforeSteamTracking"
        )
        XCTAssertEqual((capture["attempt_count"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((capture["steam_tracked_attempt_count"] as? NSNumber)?.intValue, 0)

        func attemptArtifacts() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(
                at: gameRunDirectory,
                includingPropertiesForKeys: nil
            ).filter {
                $0.lastPathComponent.hasPrefix("game-launch-attempt-") &&
                    $0.pathExtension == "json"
            }
        }
        let firstAttemptArtifacts = try attemptArtifacts()
        XCTAssertEqual(firstAttemptArtifacts.count, 1)
        let firstAttemptName = try XCTUnwrap(firstAttemptArtifacts.first?.lastPathComponent)
        let firstAttemptData = try Data(contentsOf: XCTUnwrap(firstAttemptArtifacts.first))

        _ = try XCTUnwrap(
            SteamLaunchDiagnosticsReporter().latestGameLaunchDiagnostic(
                in: steamDirectory,
                processObservationLog: observationLog,
                since: Date(timeIntervalSince1970: 100),
                observedAt: Date(timeIntervalSince1970: 180),
                persistTo: gameRunDirectory,
                forceCurrentSnapshot: true
            )
        )
        let refreshedAttemptArtifacts = try attemptArtifacts()
        XCTAssertEqual(refreshedAttemptArtifacts.map(\.lastPathComponent), [firstAttemptName])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(refreshedAttemptArtifacts.first)), firstAttemptData)
    }

    func testSupportBundleEvidenceRefreshUsesIncidentLinkedLaunchInsteadOfNewest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayIncidentRefresh-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let steamLogs = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/logs",
            directoryHint: .isDirectory
        )
        let launchLogs = try pathManager.url(for: .launchLogs)
        try FileManager.default.createDirectory(at: steamLogs, withIntermediateDirectories: true)
        for file in ["gameprocess_log.txt", "console_log.txt"] {
            try Data().write(to: steamLogs.appending(path: file))
        }

        func makeLaunchRecord(id: String, runIdentifier: String, startedAt: Date) throws -> LaunchRecord {
            let stem = "2026-07-19_00-00-00_steam_launch_\(runIdentifier)"
            let stdout = launchLogs.appending(path: "\(stem)_stdout.log")
            let stderr = launchLogs.appending(path: "\(stem)_stderr.log")
            let observation = launchLogs.appending(path: "\(stem)_process-observation.log")
            for file in [stdout, stderr, observation] {
                try Data().write(to: file)
            }
            let record = LaunchRecord(
                id: id,
                prefixId: PrefixIdentifier.steamShared,
                commandKind: "launchSteam",
                startedAt: startedAt,
                stdoutPath: stdout.path,
                stderrPath: stderr.path,
                status: "failed"
            )
            record.processObservationPath = observation.path
            return record
        }

        let selectedRunIdentifier = UUID().uuidString
        let newestRunIdentifier = UUID().uuidString
        let selected = try makeLaunchRecord(
            id: "selected-incident-launch",
            runIdentifier: selectedRunIdentifier,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let newest = try makeLaunchRecord(
            id: "newest-unrelated-launch",
            runIdentifier: newestRunIdentifier,
            startedAt: Date(timeIntervalSince1970: 200)
        )

        let result = await SteamManager(
            pathManager: pathManager,
            runner: SafeProcessRunner()
        ).refreshGameLaunchDiagnosticEvidenceForSupportBundle(
            launchRecords: [newest, selected],
            incidentLaunchRecordIdentifier: selected.id
        )

        XCTAssertEqual(result, .captured)
        XCTAssertTrue(FileSystemItemPolicy.isRegularNonSymlinkFile(
            launchLogs.appending(
                path: "GameRuns/\(selectedRunIdentifier)/game-launch-capture.json"
            )
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: launchLogs.appending(
                path: "GameRuns/\(newestRunIdentifier)/game-launch-capture.json"
            ).path
        ))
    }

    func testSupportBundleEvidenceRefreshDoesNotAcceptStaleCaptureAfterWriteFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayStaleGameCapture-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let steamLogs = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/logs",
            directoryHint: .isDirectory
        )
        let launchLogs = try pathManager.url(for: .launchLogs)
        try FileManager.default.createDirectory(at: steamLogs, withIntermediateDirectories: true)
        try Data().write(to: steamLogs.appending(path: "gameprocess_log.txt"))
        try Data().write(to: steamLogs.appending(path: "console_log.txt"))

        let runIdentifier = UUID().uuidString
        let stem = "2026-07-19_00-00-00_steam_launch_\(runIdentifier)"
        let stdout = launchLogs.appending(path: "\(stem)_stdout.log")
        let stderr = launchLogs.appending(path: "\(stem)_stderr.log")
        let observation = launchLogs.appending(path: "\(stem)_process-observation.log")
        for file in [stdout, stderr, observation] {
            try Data().write(to: file)
        }
        let record = LaunchRecord(
            id: "stale-capture-launch",
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: Date(timeIntervalSince1970: 100),
            stdoutPath: stdout.path,
            stderrPath: stderr.path,
            status: "failed"
        )
        record.processObservationPath = observation.path

        let gameRunDirectory = launchLogs.appending(
            path: "GameRuns/\(runIdentifier)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: gameRunDirectory,
            withIntermediateDirectories: true
        )
        let staleRequestIdentifier = UUID()
        let staleCapture: [String: Any] = [
            "schema_version": 1,
            "run_identifier": runIdentifier.lowercased(),
            "captured_at": "1970-01-01T00:00:00Z",
            "capture_request_identifier": staleRequestIdentifier.uuidString,
            "capture_state": "noTrackedGameProcess",
            "reason_code": "steamGameProcessNotObserved",
            "attempt_count": 0,
            "steam_tracked_attempt_count": 0,
            "inputs": [],
        ]
        try JSONSerialization.data(
            withJSONObject: staleCapture,
            options: [.sortedKeys]
        ).write(to: gameRunDirectory.appending(path: "game-launch-capture.json"))

        let fileManager = GameLaunchCaptureWriteFailureFileManager()
        fileManager.blockedDirectoryPath = gameRunDirectory.standardizedFileURL.path
        let result = await SteamManager(
            pathManager: pathManager,
            runner: SafeProcessRunner(),
            fileManager: fileManager
        ).refreshGameLaunchDiagnosticEvidenceForSupportBundle(
            launchRecords: [record],
            incidentLaunchRecordIdentifier: record.id
        )

        guard case .failed(let reason) = result else {
            return XCTFail("expected a failed refresh, got \(result)")
        }
        XCTAssertTrue(reason.contains("not refreshed for the current support request"), reason)
        let retainedData = try Data(
            contentsOf: gameRunDirectory.appending(path: "game-launch-capture.json")
        )
        let retained = try XCTUnwrap(
            JSONSerialization.jsonObject(with: retainedData) as? [String: Any]
        )
        XCTAssertEqual(
            retained["capture_request_identifier"] as? String,
            staleRequestIdentifier.uuidString
        )
    }

    func testGameLaunchDiagnosticRevisesArtifactWhenWineCrashLogArrives() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayWineCrashPersistence-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        let steamLogs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let launchLogs = root.appending(path: "Launch", directoryHint: .isDirectory)
        let observationLog = launchLogs.appending(path: "steam.process-observation.log")
        let stdoutLog = launchLogs.appending(path: "steam_stdout.log")
        let stderrLog = launchLogs.appending(path: "steam_stderr.log")
        let gameRunDirectory = launchLogs.appending(
            path: "GameRuns/\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: steamLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchLogs, withIntermediateDirectories: true)
        try Data().write(to: observationLog)
        try Data().write(to: stdoutLog)
        try Data().write(to: stderrLog)
        try Data().write(to: steamLogs.appending(path: "console_log.txt"))
        try (
            #"[2026-07-18 19:30:23] AppID 900001 adding PID 2184 as a tracked process ""G:\SteamLibrary\steamapps\common\Compatibility Sample\compatibility_sample.exe"""# + "\n" +
                "[2026-07-18 19:30:31] AppID 900001 no longer tracking PID 2184, exit code -532262845\n" +
                "[2026-07-18 19:30:31] Remove 900001 from running list\n"
        ).write(
            to: steamLogs.appending(path: "gameprocess_log.txt"),
            atomically: true,
            encoding: .utf8
        )
        let reporter = SteamLaunchDiagnosticsReporter()
        let cutoff = try steamLogDate(
            year: 2026, month: 7, day: 18, hour: 19, minute: 30, second: 22
        )
        let initial = try XCTUnwrap(reporter.latestGameLaunchDiagnostic(
            in: steamDirectory,
            processObservationLog: observationLog,
            launchStdoutLog: stdoutLog,
            launchStderrLog: stderrLog,
            since: cutoff,
            observedAt: cutoff.addingTimeInterval(20),
            persistTo: gameRunDirectory
        ))
        XCTAssertTrue(initial.runtimeCrashEvents.isEmpty)

        try (
            "wine: Unhandled exception 0xe0465043 in thread 88c at address " +
                "00006FFFFF33D8C7 (thread 088c), starting debugger...\n" +
                "088c:err:seh:start_debugger Couldn't start debugger L\"false\" (2)\n"
        ).write(to: stderrLog, atomically: true, encoding: .utf8)
        let revised = try XCTUnwrap(reporter.latestGameLaunchDiagnostic(
            in: steamDirectory,
            processObservationLog: observationLog,
            launchStdoutLog: stdoutLog,
            launchStderrLog: stderrLog,
            since: cutoff,
            observedAt: cutoff.addingTimeInterval(21),
            persistTo: gameRunDirectory
        ))

        XCTAssertEqual(revised.runtimeCrashEvents.first?.exceptionStatusHex, "0xE0465043")
        XCTAssertEqual(revised.runtimeCrashEvents.first?.threadIDHex, "0x088C")
        XCTAssertEqual(
            revised.runtimeCrashEvents.first?.automaticBacktraceState,
            .debuggerStartFailed
        )
        let persisted = try Data(
            contentsOf: gameRunDirectory.appending(path: "game-launch-diagnostic.json")
        )
        XCTAssertTrue(String(decoding: persisted, as: UTF8.self).contains("0xE0465043"))
    }

    func testDedicatedWineCrashBacktraceArrivingLateRevisesNormalizedExitArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayDedicatedWineCrash-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        let steamLogs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let launchLogs = root.appending(path: "Launch", directoryHint: .isDirectory)
        let observationLog = launchLogs.appending(path: "steam.process-observation.log")
        let stdoutLog = launchLogs.appending(path: "steam_stdout.log")
        let stderrLog = launchLogs.appending(path: "steam_stderr.log")
        let gameRunDirectory = launchLogs.appending(
            path: "GameRuns/\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: steamLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchLogs, withIntermediateDirectories: true)
        try Data().write(to: observationLog)
        try Data().write(to: stdoutLog)
        try Data().write(to: steamLogs.appending(path: "console_log.txt"))
        try (
            "wine: Unhandled exception 0xe0465043 in thread 88c at address " +
                "00006FFFFF33D8C7 (thread 088c), starting debugger...\n"
        ).write(to: stderrLog, atomically: true, encoding: .utf8)
        try (
            #"[2026-07-18 20:30:23] AppID 900001 adding PID 2184 as a tracked process ""G:\SteamLibrary\steamapps\common\Compatibility Sample\compatibility_sample.exe"""# + "\n" +
                "[2026-07-18 20:30:31] AppID 900001 no longer tracking PID 2184, exit code 1\n" +
                "[2026-07-18 20:30:31] Remove 900001 from running list\n"
        ).write(
            to: steamLogs.appending(path: "gameprocess_log.txt"),
            atomically: true,
            encoding: .utf8
        )
        let cutoff = try steamLogDate(
            year: 2026, month: 7, day: 18, hour: 20, minute: 30, second: 22
        )
        let reporter = SteamLaunchDiagnosticsReporter(
            dedicatedWineCrashCapabilityEnabled: true
        )
        let initial = try XCTUnwrap(reporter.latestGameLaunchDiagnostic(
            in: steamDirectory,
            processObservationLog: observationLog,
            launchStdoutLog: stdoutLog,
            launchStderrLog: stderrLog,
            since: cutoff,
            observedAt: cutoff.addingTimeInterval(20),
            persistTo: gameRunDirectory
        ))
        let diagnosticURL = gameRunDirectory.appending(path: "game-launch-diagnostic.json")
        let initialArtifact = try Data(contentsOf: diagnosticURL)

        XCTAssertEqual(initial.primaryExitCode, 1)
        XCTAssertEqual(initial.runtimeCrashEvents.first?.exceptionStatusHex, "0xE0465043")
        XCTAssertEqual(initial.runtimeCrashEvents.first?.automaticBacktraceState, .notCaptured)
        XCTAssertEqual(
            initial.runtimeCrashEvents.first?.correlationBasis,
            "boundedOneToOneReverseSteamLaunchSessionOrderAfterStatusMismatch"
        )
        XCTAssertEqual(initial.runtimeCrashDedicatedEvidenceState, SteamEvidenceReadState.missing.rawValue)

        try (
            "FORGEPLAY_WINE_CRASH_V1 target-pid-decimal=2184 debugger-pid-decimal=9012 output-limit-bytes=4194304\n" +
                "WineDbg attached to pid 0888\n" +
                "Unhandled exception: 0xe0465043 in 64-bit code (0x006fffff33d8c7).\n" +
                "Backtrace:\n" +
                "=>0 0x006fffff33d8c7 in kernelbase (+0xd8c7) (0x0000000031fea0)\n" +
                "  1 0x000001400014bc in compatibility_sample (+0x14bc) (0x0000000031fea0)\n" +
                "Modules:\n" +
                "System information:\n" +
                "Wine build: wine-11.12\n" +
                "Host system: Darwin\n"
        ).write(
            to: gameRunDirectory.appending(path: "wine-crash-2184-9012.log"),
            atomically: true,
            encoding: .utf8
        )
        let revised = try XCTUnwrap(reporter.latestGameLaunchDiagnostic(
            in: steamDirectory,
            processObservationLog: observationLog,
            launchStdoutLog: stdoutLog,
            launchStderrLog: stderrLog,
            since: cutoff,
            observedAt: cutoff.addingTimeInterval(21),
            persistTo: gameRunDirectory
        ))
        let revisedArtifact = try Data(contentsOf: diagnosticURL)

        XCTAssertNotEqual(initialArtifact, revisedArtifact)
        XCTAssertEqual(revised.runtimeCrashEvents.first?.windowsProcessID, 2184)
        XCTAssertEqual(revised.runtimeCrashEvents.first?.automaticBacktraceState, .captured)
        XCTAssertEqual(revised.runtimeCrashEvents.first?.backtraceFrames.count, 2)
        XCTAssertEqual(
            revised.runtimeCrashEvents.first?.correlationBasis,
            "windowsProcessIDWithSteamNormalizedExitStatus"
        )
        XCTAssertEqual(revised.runtimeCrashDedicatedEvidenceState, SteamEvidenceReadState.captured.rawValue)
        XCTAssertTrue(revised.runtimeCrashDedicatedEvidenceDetail?.contains("accepted 1 of 1") == true)
        XCTAssertTrue(String(decoding: revisedArtifact, as: UTF8.self).contains("compatibility_sample (+0x14bc)"))
    }

    func testRawWineExceptionsUseBoundedOneToOneFallbackOnlyWithinSameLaunchSession() throws {
        let observations = WineRuntimeCrashEventParser.parse(
            stdoutLines: [],
            stderrLines: [
                "wine: Unhandled exception 0xe0465043 in thread 88c at address " +
                    "00006FFFFF33D8C7 (thread 088c), starting debugger...",
                "wine: Unhandled exception 0xc0000005 in thread 8bc at address " +
                    "0000000140001234 (thread 08bc), starting debugger..."
            ]
        )
        let startedAt = try steamLogDate(
            year: 2026, month: 7, day: 18, hour: 20, minute: 40, second: 0
        )
        let processLines = [
            #"[2026-07-18 20:40:00] AppID 111 adding PID 2100 as a tracked process ""G:\First\first.exe"""#,
            "[2026-07-18 20:40:02] AppID 111 no longer tracking PID 2100, exit code 1",
            "[2026-07-18 20:40:02] Remove 111 from running list",
            #"[2026-07-18 20:40:04] AppID 222 adding PID 2200 as a tracked process ""G:\Second\second.exe"""#,
            "[2026-07-18 20:40:06] AppID 222 no longer tracking PID 2200, exit code 1",
            "[2026-07-18 20:40:06] Remove 222 from running list"
        ]

        let strictDiagnostics = SteamGameLaunchDiagnosticAnalyzer.analyzeAttempts(
            gameProcessLines: processLines,
            consoleLines: [],
            processObservation: SteamProcessCreationObservationLog.parseResult(Data()),
            runtimeCrashObservations: observations,
            allowsSameLaunchSessionOrderFallback: false,
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(20)
        )
        XCTAssertTrue(strictDiagnostics.allSatisfy { $0.runtimeCrashEvents.isEmpty })

        let scopedDiagnostics = SteamGameLaunchDiagnosticAnalyzer.analyzeAttempts(
            gameProcessLines: processLines,
            consoleLines: [],
            processObservation: SteamProcessCreationObservationLog.parseResult(Data()),
            runtimeCrashObservations: observations,
            allowsSameLaunchSessionOrderFallback: true,
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(20)
        )
        XCTAssertEqual(scopedDiagnostics.count, 2)
        XCTAssertEqual(scopedDiagnostics[0].runtimeCrashEvents.first?.exceptionStatusHex, "0xE0465043")
        XCTAssertEqual(scopedDiagnostics[1].runtimeCrashEvents.first?.exceptionStatusHex, "0xC0000005")
        XCTAssertEqual(
            scopedDiagnostics.map { $0.runtimeCrashEvents.first?.correlationBasis },
            [
                "boundedOneToOneReverseSteamLaunchSessionOrderAfterStatusMismatch",
                "boundedOneToOneReverseSteamLaunchSessionOrderAfterStatusMismatch"
            ]
        )
    }

    func testGameLaunchDiagnosticPersistsFastRetriesAsDistinctDeduplicatedArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayGameAttemptHistory-\(UUID().uuidString)", directoryHint: .isDirectory)
        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        let steamLogs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let launchLogs = root.appending(path: "Launch", directoryHint: .isDirectory)
        let observationLog = launchLogs.appending(path: "steam.process-observation.log")
        let gameRunDirectory = launchLogs.appending(
            path: "GameRuns/\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: steamLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchLogs, withIntermediateDirectories: true)
        try Data("\n".utf8).write(to: observationLog)
        try Data().write(to: steamLogs.appending(path: "console_log.txt"))
        let gameProcessLog = steamLogs.appending(path: "gameprocess_log.txt")
        let firstExecutable = #"G:\SteamLibrary\steamapps\common\First\first.exe"#
        let secondExecutable = #"G:\SteamLibrary\steamapps\common\Second\second.exe"#
        let initialLog = """
        [2026-07-17 05:10:00] AppID 111 adding PID 1800 as a tracked process ""\(firstExecutable)""
        [2026-07-17 05:10:02] AppID 111 no longer tracking PID 1800, exit code 7
        [2026-07-17 05:10:03] Remove 111 from running list
        [2026-07-17 05:10:04] AppID 222 adding PID 1801 as a tracked process ""\(secondExecutable)""
        """ + "\n"
        try initialLog.write(to: gameProcessLog, atomically: true, encoding: .utf8)
        let reporter = SteamLaunchDiagnosticsReporter()
        let cutoff = try steamLogDate(year: 2026, month: 7, day: 17, hour: 5, minute: 9, second: 59)
        let firstObservation = try steamLogDate(
            year: 2026, month: 7, day: 17, hour: 5, minute: 10, second: 40
        )

        let latest = try XCTUnwrap(reporter.latestGameLaunchDiagnostic(
            in: steamDirectory,
            processObservationLog: observationLog,
            since: cutoff,
            observedAt: firstObservation,
            persistTo: gameRunDirectory
        ))
        XCTAssertEqual(latest.appID, "222")
        XCTAssertEqual(latest.state, .running)

        func attemptArtifacts() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(
                at: gameRunDirectory,
                includingPropertiesForKeys: nil
            ).filter {
                $0.lastPathComponent.hasPrefix("game-launch-attempt-") &&
                    $0.pathExtension == "json"
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        let initialArtifacts = try attemptArtifacts()
        XCTAssertEqual(initialArtifacts.count, 2)
        let initialArtifactData = Dictionary(uniqueKeysWithValues: try initialArtifacts.map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })
        let documents = try initialArtifacts.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any])
        }
        XCTAssertTrue(documents.allSatisfy { ($0["schema_version"] as? NSNumber)?.intValue == 1 })
        XCTAssertTrue(documents.allSatisfy { ($0["attempt_identifier"] as? String)?.hasPrefix("v1-") == true })
        XCTAssertTrue(documents.allSatisfy { ($0["material_revision"] as? String)?.count == 64 })
        XCTAssertEqual(
            Set(documents.compactMap { ($0["diagnostic"] as? [String: Any])?["appID"] as? String }),
            ["111", "222"]
        )

        _ = try XCTUnwrap(reporter.latestGameLaunchDiagnostic(
            in: steamDirectory,
            processObservationLog: observationLog,
            since: cutoff,
            observedAt: firstObservation.addingTimeInterval(30),
            persistTo: gameRunDirectory,
            forceCurrentSnapshot: true
        ))
        let unchangedArtifacts = try attemptArtifacts()
        XCTAssertEqual(unchangedArtifacts.map(\.lastPathComponent), initialArtifacts.map(\.lastPathComponent))
        for artifact in unchangedArtifacts {
            XCTAssertEqual(try Data(contentsOf: artifact), initialArtifactData[artifact.lastPathComponent])
        }

        let thirdExecutable = #"G:\SteamLibrary\steamapps\common\Third\third.exe"#
        try (
            initialLog +
                "[2026-07-17 05:11:20] AppID 333 adding PID 1802 as a tracked process \"\"\(thirdExecutable)\"\"\n"
        ).write(to: gameProcessLog, atomically: true, encoding: .utf8)
        let retried = try XCTUnwrap(reporter.latestGameLaunchDiagnostic(
            in: steamDirectory,
            processObservationLog: observationLog,
            since: cutoff,
            observedAt: firstObservation.addingTimeInterval(50),
            persistTo: gameRunDirectory
        ))
        XCTAssertEqual(retried.appID, "333")
        let retriedArtifacts = try attemptArtifacts()
        XCTAssertEqual(retriedArtifacts.count, 3)
        for artifact in retriedArtifacts where initialArtifactData[artifact.lastPathComponent] != nil {
            XCTAssertEqual(try Data(contentsOf: artifact), initialArtifactData[artifact.lastPathComponent])
        }
        let latestDocument = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: gameRunDirectory.appending(path: "game-launch-diagnostic.json"))
            ) as? [String: Any]
        )
        XCTAssertEqual(latestDocument["appID"] as? String, "333")
    }

    func testGameLaunchDiagnosticAttemptArtifactHistoryIsBounded() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayGameAttemptLimit-\(UUID().uuidString)", directoryHint: .isDirectory)
        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        let steamLogs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let launchLogs = root.appending(path: "Launch", directoryHint: .isDirectory)
        let observationLog = launchLogs.appending(path: "steam.process-observation.log")
        let gameRunDirectory = launchLogs.appending(
            path: "GameRuns/\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: steamLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchLogs, withIntermediateDirectories: true)
        try Data("\n".utf8).write(to: observationLog)
        try Data().write(to: steamLogs.appending(path: "console_log.txt"))
        var lines: [String] = []
        for index in 0..<70 {
            let minute = 20 + index / 30
            let second = (index % 30) * 2
            let appID = 10_000 + index
            let processID = 20_000 + index
            lines.append(String(
                format: "[2026-07-17 05:%02d:%02d] AppID %d adding PID %d as a tracked process \"\"G:\\\\Game\\\\game.exe\"\"",
                minute,
                second,
                appID,
                processID
            ))
            lines.append(String(
                format: "[2026-07-17 05:%02d:%02d] AppID %d no longer tracking PID %d, exit code 1",
                minute,
                second + 1,
                appID,
                processID
            ))
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: steamLogs.appending(path: "gameprocess_log.txt"),
            atomically: true,
            encoding: .utf8
        )
        let observedAt = try steamLogDate(
            year: 2026, month: 7, day: 17, hour: 5, minute: 23, second: 0
        )
        _ = try XCTUnwrap(SteamLaunchDiagnosticsReporter().latestGameLaunchDiagnostic(
            in: steamDirectory,
            processObservationLog: observationLog,
            since: observedAt.addingTimeInterval(-300),
            observedAt: observedAt,
            persistTo: gameRunDirectory
        ))
        let artifacts = try FileManager.default.contentsOfDirectory(
            at: gameRunDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("game-launch-attempt-") }

        XCTAssertEqual(artifacts.count, 64)
    }

    func testGameLaunchDiagnosticPromotesCorrelatedRendererError() throws {
        let executable = #"G:\SteamLibrary\steamapps\common\Game\game.exe"#
        let processObservation = SteamProcessCreationObservationLog.parseResult(Data((
            "FORGEPLAY_GAME_RENDERER_V1\t1600\trequested=d3dMetal | applied=d3dMetal | " +
                "reason=automatic-d3d12 | evidence=pe32+;import=d3d12.dll | \(executable)\n" +
                "FORGEPLAY_GAME_RENDERER_ERROR_V1\t1600\tloader-dll-path | " +
                "status=0xC0000135 | d3d12.dll\n"
        ).utf8))
        let startedAt = try steamLogDate(year: 2026, month: 7, day: 17, hour: 4, minute: 31, second: 0)
        let diagnostic = try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [
                "[2026-07-17 04:31:00] AppID 888 adding PID 1600 as a tracked process \"\"\(executable)\"\""
            ],
            consoleLines: [],
            processObservation: processObservation,
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(2)
        ))

        XCTAssertEqual(diagnostic.state, .rendererError)
        XCTAssertEqual(diagnostic.rendererErrorStage, "loader-dll-path")
        XCTAssertEqual(diagnostic.rendererErrorStatusHex, "0xC0000135")
        XCTAssertTrue(diagnostic.correlatedEvidence.contains { $0.contains("renderer error") })
    }

    func testGameLaunchDiagnosticPromotesLoaderErrorWrittenBeforeMatchingRoute() throws {
        let executable = #"G:\SteamLibrary\steamapps\common\Game\game.exe"#
        let processObservation = SteamProcessCreationObservationLog.parseResult(Data((
            "FORGEPLAY_GAME_RENDERER_ERROR_V1\t1600\tloader-dll-path | " +
                "status=0xC0000135 | d3d12.dll\n" +
                "FORGEPLAY_GAME_RENDERER_V1\t1600\trequested=d3dMetal | applied=d3dMetal | " +
                "reason=automatic-d3d12 | evidence=pe32+;import=d3d12.dll | \(executable)\n"
        ).utf8))
        let startedAt = try steamLogDate(
            year: 2026, month: 7, day: 17, hour: 4, minute: 31, second: 5
        )
        let diagnostic = try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [
                "[2026-07-17 04:31:05] AppID 888 adding PID 1600 as a tracked process " +
                    "\"\"\(executable)\"\""
            ],
            consoleLines: [],
            processObservation: processObservation,
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(2)
        ))

        XCTAssertEqual(diagnostic.state, .rendererError)
        XCTAssertEqual(diagnostic.rendererErrorStage, "loader-dll-path")
        XCTAssertEqual(diagnostic.rendererErrorStatusHex, "0xC0000135")
    }

    func testGameLaunchDiagnosticDoesNotReuseDLLOnlyErrorAfterPIDReuse() throws {
        let priorExecutable = #"G:\SteamLibrary\steamapps\common\Prior\game.exe"#
        let currentExecutable = #"G:\SteamLibrary\steamapps\common\Current\game.exe"#
        let processObservation = SteamProcessCreationObservationLog.parseResult(Data((
            "FORGEPLAY_GAME_RENDERER_V1\t1601\trequested=dxmt | applied=dxmt | " +
                "reason=automatic-d3d11-dxmt | evidence=pe32;import=d3d11.dll | " +
                "\(priorExecutable)\n" +
                "FORGEPLAY_GAME_RENDERER_ERROR_V1\t1601\tloader-dll-path | " +
                "status=0xC0000135 | d3d11.dll\n" +
                "FORGEPLAY_GAME_RENDERER_V1\t1601\trequested=d3dMetal | applied=d3dMetal | " +
                "reason=automatic-d3d12 | evidence=pe32+;import=d3d12.dll | " +
                "\(currentExecutable)\n"
        ).utf8))
        let startedAt = try steamLogDate(
            year: 2026, month: 7, day: 17, hour: 4, minute: 31, second: 10
        )
        let diagnostic = try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [
                "[2026-07-17 04:31:10] AppID 889 adding PID 1601 as a tracked process " +
                    "\"\"\(currentExecutable)\"\""
            ],
            consoleLines: [],
            processObservation: processObservation,
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(2)
        ))

        XCTAssertEqual(diagnostic.state, .launching)
        XCTAssertEqual(diagnostic.executable, currentExecutable)
        XCTAssertEqual(diagnostic.rendererPlannedProfile, "d3dMetal")
        XCTAssertNil(diagnostic.rendererErrorStage)
        XCTAssertNil(diagnostic.rendererErrorStatusHex)
    }

    func testGameRendererObservationParserRecoversNewestCompleteRecordFromOversizedInput() {
        let executable = #"D:\SteamLibrary\steamapps\common\Game\game.exe"#
        var oversized = Data(repeating: 0x61, count: 1024 * 1024 + 256)
        oversized.append(0x0a)
        oversized.append(contentsOf: "FORGEPLAY_GAME_RENDERER_V1\t72009\tvulkan | \(executable)\n".utf8)

        let result = SteamProcessCreationObservationLog.parseResult(oversized)

        XCTAssertEqual(result.gameRendererObservations.map(\.processID), [72_009])
        XCTAssertEqual(result.state, .recovered)
        XCTAssertTrue(result.issues.contains { $0.code == .oversizedTailRecovered })
    }

    func testProcessObservationParserRetainsNewestRecordsWhenRecordLimitIsExceeded() {
        let command = #"C:\Program Files (x86)\Steam\bin\cef\steamwebhelper.exe --no-sandbox"#
        let data = Data((1...4_100).map { processID in
            "FORGEPLAY_PROCESS_V1\t\(processID)\t\(command)"
        }.joined(separator: "\n").appending("\n").utf8)

        let result = SteamProcessCreationObservationLog.parseResult(data)

        XCTAssertEqual(result.processes.count, 4_096)
        XCTAssertEqual(result.processes.first?.processID, 5)
        XCTAssertEqual(result.processes.last?.processID, 4_100)
        XCTAssertEqual(
            result.issues.first(where: { $0.code == .recordLimitApplied })?.affectedRecordCount,
            4
        )
    }

    func testProcessObservationParserSkipsInvalidUTF8AndTrailingPartialRecordIndependently() {
        let command = #"C:\Program Files (x86)\Steam\bin\cef\steamwebhelper.exe --no-sandbox"#
        var data = Data("FORGEPLAY_PROCESS_V1\t73001\t\(command)\n".utf8)
        data.append(contentsOf: [0xff, 0xfe, 0x0a])
        data.append(contentsOf: "FORGEPLAY_PROCESS_V1\t73002\t\(command)\n".utf8)
        data.append(contentsOf: "FORGEPLAY_PROCESS_V1\t73003\t\(command)".utf8)

        let result = SteamProcessCreationObservationLog.parseResult(data)

        XCTAssertEqual(result.processes.map(\.processID), [73_001, 73_002])
        XCTAssertEqual(result.state, .recovered)
        XCTAssertTrue(result.issues.contains { $0.code == .invalidUTF8RecordDiscarded })
        XCTAssertTrue(result.issues.contains { $0.code == .trailingPartialRecordDiscarded })
    }

    func testProcessObservationFileReadReportsOpenFailureWithoutDiscardingStatus() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayObservationRead-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target.log")
        let symlink = root.appending(path: "observation.log")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let result = SteamProcessCreationObservationLog.read(at: symlink)

        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(result.issues.first?.code, .openFailed)
        XCTAssertNotNil(result.diagnosticWarning)
    }

    func testSameRunLaunchEvidenceCombinesKnownRunnerWithWineWebHelperObservation() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySameRunEvidence-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        let runner = temporaryRoot.appending(path: "ForgePlayRuntime/wine/bin/wine")
        let prefix = temporaryRoot.appending(path: "Prefixes/SteamShared", directoryHint: .isDirectory)
        let steamExecutable = prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
        let observationLog = temporaryRoot.appending(path: "steam.process-observation.log")
        let rootWebHelperCommand = #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --no-sandbox --in-process-gpu --disable-gpu"#
        let typedWebHelperCommand = #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --type=renderer --no-sandbox"#
        try [
            "FORGEPLAY_PROCESS_V1\t72002\t\(rootWebHelperCommand)",
            "FORGEPLAY_PROCESS_V1\t72003\t\(typedWebHelperCommand)"
        ].joined(separator: "\n").appending("\n").write(
            to: observationLog,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: observationLog.path)

        let now = Date()
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: runner,
            arguments: [#"C:\Program Files (x86)\Steam\steam.exe"#],
            startedAt: now,
            endedAt: now,
            exitCode: 0,
            stdoutLog: temporaryRoot.appending(path: "stdout.log"),
            stderrLog: temporaryRoot.appending(path: "stderr.log"),
            didTimeOut: false,
            waitedForExit: false,
            processIdentifier: 72_001,
            processObservationLog: observationLog
        )
        let target = SteamLaunchTarget(
            expectedRunnerPath: runner,
            expectedPrefixPath: prefix,
            expectedSteamExecutablePath: steamExecutable
        )

        let evidence = SteamLaunchProcessSnapshot.sameRunLaunchEvidence(for: result, target: target)

        XCTAssertEqual(
            evidence.processes.map(\.processID),
            [72_001, 72_002, 72_003]
        )
        XCTAssertEqual(
            evidence.processes.map { $0.identifier.namespace },
            [.darwin, .windows, .windows]
        )
        XCTAssertTrue(evidence.containsExpectedRunnerProcess(for: target))
        XCTAssertTrue(evidence.containsExpectedPrefixSteamProcess(for: target))
        XCTAssertTrue(evidence.webHelperCommandLinesContainRequiredLaunchPolicy(for: target))
        XCTAssertEqual(
            evidence.webHelperCommandLines(for: target),
            [
                "PID 72002: \(rootWebHelperCommand)",
                "PID 72003: \(typedWebHelperCommand)"
            ]
        )

        var exitedLauncherResult = result
        exitedLauncherResult.waitedForExit = true
        let exitedLauncherEvidence = SteamLaunchProcessSnapshot.sameRunLaunchEvidence(
            for: exitedLauncherResult,
            target: target
        )
        XCTAssertEqual(
            exitedLauncherEvidence.processes.map(\.processID),
            [72_002, 72_003]
        )
        XCTAssertFalse(exitedLauncherEvidence.containsExpectedRunnerProcess(for: target))
        XCTAssertTrue(exitedLauncherEvidence.containsExpectedPrefixSteamProcess(for: target))
    }

    func testSameRunRunnerPIDDoesNotClaimWindowsSteamStarted() {
        let runner = URL(fileURLWithPath: "/Runtime/wine/bin/wine")
        let prefix = URL(fileURLWithPath: "/Managed/Prefixes/SteamShared")
        let steamExecutable = prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
        let now = Date()
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: runner,
            arguments: [#"C:\Program Files (x86)\Steam\steam.exe"#],
            startedAt: now,
            endedAt: now,
            exitCode: 0,
            stdoutLog: URL(fileURLWithPath: "/tmp/stdout.log"),
            stderrLog: URL(fileURLWithPath: "/tmp/stderr.log"),
            didTimeOut: false,
            waitedForExit: false,
            processIdentifier: 72_001
        )
        let target = SteamLaunchTarget(
            expectedRunnerPath: runner,
            expectedPrefixPath: prefix,
            expectedSteamExecutablePath: steamExecutable
        )

        let evidence = SteamLaunchProcessSnapshot.sameRunLaunchEvidence(for: result, target: target)

        XCTAssertTrue(evidence.containsExpectedRunnerProcess(for: target))
        XCTAssertFalse(evidence.containsExpectedPrefixSteamProcess(for: target))
    }

    func testProcessCreationEvidenceDoesNotCompareWindowsPIDToDarwinPID() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayHistoricalProcessEvidence-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let observationLog = temporaryRoot.appending(path: "process-observations.log")
        try "FORGEPLAY_PROCESS_V1\t72002\tC:\\Program Files (x86)\\Steam\\steamwebhelper.exe\n".write(
            to: observationLog,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: observationLog.path)
        let now = Date()
        let target = SteamLaunchTarget(
            expectedRunnerPath: temporaryRoot.appending(path: "wine"),
            expectedPrefixPath: temporaryRoot.appending(path: "prefix"),
            expectedSteamExecutablePath: temporaryRoot.appending(path: "prefix/drive_c/Steam/steam.exe")
        )
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: target.expectedRunnerPath,
            arguments: [],
            startedAt: now,
            endedAt: now,
            exitCode: 0,
            stdoutLog: temporaryRoot.appending(path: "stdout.log"),
            stderrLog: temporaryRoot.appending(path: "stderr.log"),
            didTimeOut: false,
            waitedForExit: false,
            processObservationLog: observationLog
        )

        let evidence = SteamLaunchProcessSnapshot.sameRunLaunchEvidence(for: result, target: target)
        XCTAssertTrue(evidence.containsExpectedPrefixSteamProcess(for: target))
        XCTAssertEqual(evidence.processes.first?.identifier.namespace, .windows)
        XCTAssertTrue(
            evidence
                .reconcilingProcessCreationEvidence(
                    with: SteamLaunchProcessSnapshot(processes: [])
                )
                .containsExpectedPrefixSteamProcess(for: target)
        )
        XCTAssertTrue(
            evidence
                .reconcilingProcessCreationEvidence(
                    with: SteamLaunchProcessSnapshot(processes: [
                        SteamLaunchObservedProcess(
                            processID: 72002,
                            command: "/usr/bin/unrelated-darwin-process"
                        )
                    ])
                )
                .containsExpectedPrefixSteamProcess(for: target)
        )
        XCTAssertFalse(
            evidence
                .reconcilingProcessCreationEvidence(
                    with: SteamLaunchProcessSnapshot(processes: [
                        SteamLaunchObservedProcess(
                            processID: 72003,
                            command: "C:\\Program Files (x86)\\Steam\\steamwebhelper.exe",
                            evidenceSource: .processCreationObservation
                        )
                    ])
                )
                .containsExpectedPrefixSteamProcess(for: target)
        )
    }

    func testDarwinProcessSnapshotReaderFindsRelevantProcessWithoutExternalPS() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayNativeProcessSnapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let executable = temporaryRoot.appending(path: "wine")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let deadline = Date().addingTimeInterval(2)
        var observed: SteamLaunchObservedProcess?
        repeat {
            observed = DarwinProcessSnapshotReader.current().processes.first {
                $0.processID == process.processIdentifier
            }
            if observed == nil { Thread.sleep(forTimeInterval: 0.05) }
        } while observed == nil && Date() < deadline

        let processEvidence = try XCTUnwrap(observed)
        XCTAssertEqual(processEvidence.identifier.namespace, .darwin)
        XCTAssertTrue(processEvidence.command.contains(executable.path), processEvidence.command)
        XCTAssertTrue(processEvidence.command.contains("30"), processEvidence.command)
    }

    func testSteamLaunchProcessSnapshotSeparatesExpectedTargetFromContamination() {
        let target = SteamLaunchTarget(
            expectedRunnerPath: URL(fileURLWithPath: "/Applications/ForgePlay.app/Contents/Resources/Runners/ForgePlayRuntime/wine/bin/wine"),
            expectedPrefixPath: URL(fileURLWithPath: "/Volumes/ForgePlay/Prefixes/SteamShared"),
            expectedSteamExecutablePath: URL(fileURLWithPath: "/Volumes/ForgePlay/Prefixes/SteamShared/drive_c/Program Files (x86)/Steam/steam.exe")
        )
        let output = """
          301 /Applications/ForgePlay.app/Contents/Resources/Runners/ForgePlayRuntime/wine/bin/wine C:\\Program Files (x86)\\Steam\\steam.exe WINEPREFIX=/Volumes/ForgePlay/Prefixes/SteamShared
          302 /Applications/ForgePlay.app/Contents/Resources/Runners/ForgePlayRuntime/wine/bin/wineserver WINEPREFIX=/Volumes/ForgePlay/Prefixes/SteamShared
          303 C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win64\\steamwebhelper.exe WINEPREFIX=/Volumes/ForgePlay/Prefixes/SteamShared
          304 /Volumes/OtherRuntime/bin/wine C:\\Program Files (x86)\\Steam\\steam.exe WINEPREFIX=/Volumes/OtherPrefix
          305 C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win64\\steamwebhelper.exe WINEPREFIX=/Volumes/OtherPrefix
          306 /Applications/ThirdPartyRuntime.app/Contents/Resources/Runtime/bin/wine C:\\Program Files (x86)\\Steam\\steam.exe
          307 /Users/tester/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/ipcserver
        """

        let snapshot = SteamLaunchProcessSnapshot(processes: SteamLaunchProcessSnapshot.parsePSOutput(output))

        XCTAssertTrue(snapshot.containsExpectedRunnerProcess(for: target))
        XCTAssertTrue(snapshot.containsExpectedPrefixSteamProcess(for: target))
        XCTAssertEqual(snapshot.webHelperCommandLines(for: target).map { $0.contains("PID 303") }, [true])
        XCTAssertEqual(snapshot.externalApplicationRunnerProcesses.map(\.processID), [306])
        XCTAssertEqual(snapshot.hostMacOSSteamProcesses.map(\.processID), [307])
        XCTAssertEqual(
            snapshot.steamOrWineProcessesOutsideTarget(for: target).map(\.processID),
            [304, 305, 306]
        )
    }

    func testSteamLaunchProcessSnapshotRejectsCaseVariantPrefixSibling() {
        let target = SteamLaunchTarget(
            expectedRunnerPath: URL(fileURLWithPath: "/Volumes/CaseSensitive/Runtime/bin/wine"),
            expectedPrefixPath: URL(fileURLWithPath: "/Volumes/CaseSensitive/ForgePlay/Prefixes/SteamShared"),
            expectedSteamExecutablePath: URL(
                fileURLWithPath: "/Volumes/CaseSensitive/ForgePlay/Prefixes/SteamShared/drive_c/Program Files (x86)/Steam/steam.exe"
            )
        )
        let caseVariant = SteamLaunchProcessSnapshot(processes: [
            SteamLaunchObservedProcess(
                processID: 81001,
                command: "WINEPREFIX=/Volumes/CaseSensitive/forgeplay/Prefixes/SteamShared " +
                    "/Volumes/CaseSensitive/Runtime/bin/wine C:\\\\Program Files (x86)\\\\Steam\\\\steam.exe"
            )
        ])

        XCTAssertFalse(caseVariant.containsExpectedPrefixSteamProcess(for: target))
        XCTAssertEqual(caseVariant.steamOrWineProcessesOutsideTarget(for: target).map(\.processID), [81001])
    }

    func testSteamLaunchProcessSnapshotRejectsExternalAppBundledRunnerAsExpectedRunner() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalRunnerSnapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let externalApplicationRoot = temporaryRoot
            .appending(path: "ThirdPartyRuntime.app/Contents/Resources/Runtime", directoryHint: .isDirectory)
        let runnerDirectory = externalApplicationRoot.appending(path: "bin", directoryHint: .isDirectory)
        let hostedWine = runnerDirectory.appending(path: "wine")
        try FileManager.default.createDirectory(at: runnerDirectory, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        exit 0
        """.write(to: hostedWine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hostedWine.path)

        let prefix = temporaryRoot
            .appending(path: "Prefixes/ForgePlaySteamTest", directoryHint: .isDirectory)
        let target = SteamLaunchTarget(
            expectedRunnerPath: hostedWine,
            expectedPrefixPath: prefix,
            expectedSteamExecutablePath: prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
        )
        let output = """
          401 \(externalApplicationRoot.path)/bin/wine C:\\Program Files (x86)\\Steam\\steam.exe -no-cef-sandbox
          402 \(externalApplicationRoot.path)/bin/wineserver
          403 C:\\Program Files (x86)\\Steam\\steam.exe -no-cef-sandbox
          404 C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win7x64\\steamwebhelper.exe --disable-gpu
        """

        let snapshot = SteamLaunchProcessSnapshot(processes: SteamLaunchProcessSnapshot.parsePSOutput(output))

        XCTAssertFalse(snapshot.containsExpectedRunnerProcess(for: target))
        XCTAssertFalse(snapshot.containsExpectedPrefixSteamProcess(for: target))
        XCTAssertTrue(snapshot.webHelperCommandLines(for: target).isEmpty)
        XCTAssertEqual(snapshot.externalApplicationRunnerProcesses.map(\.processID), [401, 402])
        XCTAssertEqual(snapshot.steamOrWineProcessesOutsideTarget(for: target).map(\.processID), [401, 402, 403, 404])
    }

    func testSteamLaunchProcessSnapshotRequiresSameRunObservationForUnscopedWindowsPaths() {
        let target = SteamLaunchTarget(
            expectedRunnerPath: URL(fileURLWithPath: "/Volumes/Runtime/ForgePlayRuntime/wine/bin/wine"),
            expectedPrefixPath: URL(fileURLWithPath: "/Users/example/Library/Application Support/ForgePlay/Prefixes/SteamShared"),
            expectedSteamExecutablePath: URL(fileURLWithPath: "/Users/example/Library/Application Support/ForgePlay/Prefixes/SteamShared/drive_c/Program Files (x86)/Steam/steam.exe")
        )
        let output = """
          501 /Volumes/Runtime/ForgePlayRuntime/wine/bin/wineserver
          502 C:\\Program Files (x86)\\Steam\\steam.exe -no-cef-sandbox
          503 C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win7x64\\steamwebhelper.exe --no-sandbox
        """

        let unscopedSnapshot = SteamLaunchProcessSnapshot(
            processes: SteamLaunchProcessSnapshot.parsePSOutput(output)
        )

        XCTAssertTrue(unscopedSnapshot.containsExpectedRunnerProcess(for: target))
        XCTAssertFalse(unscopedSnapshot.containsExpectedPrefixSteamProcess(for: target))
        XCTAssertTrue(unscopedSnapshot.webHelperCommandLines(for: target).isEmpty)
        XCTAssertEqual(
            Set(unscopedSnapshot.steamOrWineProcessesOutsideTarget(for: target).map(\.processID)),
            Set([502, 503])
        )

        let observation = Data(
            "FORGEPLAY_PROCESS_V1\t503\tC:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win7x64\\steamwebhelper.exe --no-sandbox\n".utf8
        )
        let sameRunSnapshot = SteamLaunchProcessSnapshot(
            processes: [
                SteamLaunchObservedProcess(
                    processID: 501,
                    command: "/Volumes/Runtime/ForgePlayRuntime/wine/bin/wineserver"
                )
            ] +
                SteamProcessCreationObservationLog.parse(observation)
        )

        XCTAssertTrue(sameRunSnapshot.containsExpectedPrefixSteamProcess(for: target))
        XCTAssertEqual(sameRunSnapshot.webHelperCommandLines(for: target).map { $0.contains("PID 503") }, [true])
        XCTAssertEqual(sameRunSnapshot.steamOrWineProcessesOutsideTarget(for: target), [])
    }

    func testExternalApplicationRunnerCannotSatisfyForgePlayPrefixSteamEvidence() {
        let target = SteamLaunchTarget(
            expectedRunnerPath: URL(fileURLWithPath: "/Applications/ForgePlay.app/Contents/Resources/Runners/ForgePlayRuntime/wine/bin/wine"),
            expectedPrefixPath: URL(fileURLWithPath: "/Users/example/Library/Application Support/ForgePlay/ManagedData/Prefixes/SteamShared"),
            expectedSteamExecutablePath: URL(fileURLWithPath: "/Users/example/Library/Application Support/ForgePlay/ManagedData/Prefixes/SteamShared/drive_c/Program Files (x86)/Steam/steam.exe")
        )
        let snapshot = SteamLaunchProcessSnapshot(processes: [
            SteamLaunchObservedProcess(
                processID: 901,
                command: "/Applications/ThirdPartyRuntime.app/Contents/Resources/Runtime/bin/wine C:\\Program Files (x86)\\Steam\\steam.exe WINEPREFIX=\(target.expectedPrefixPath.path)"
            ),
            SteamLaunchObservedProcess(
                processID: 902,
                command: "/Applications/ThirdPartyRuntime.app/Contents/Resources/Runtime/bin/wine C:\\Program Files (x86)\\Steam\\bin\\cef\\steamwebhelper.exe --no-sandbox --in-process-gpu --disable-gpu",
                evidenceSource: .processCreationObservation
            )
        ])

        XCTAssertFalse(snapshot.containsExpectedPrefixSteamProcess(for: target))
        XCTAssertTrue(snapshot.webHelperCommandLines(for: target).isEmpty)
        XCTAssertEqual(Set(snapshot.steamOrWineProcessesOutsideTarget(for: target).map(\.processID)), Set([901, 902]))
    }

    func testSiblingPrefixPathDoesNotSatisfyForgePlaySteamEvidence() {
        let prefix = URL(fileURLWithPath: "/Users/example/ForgePlay/Prefixes/SteamShared")
        let target = SteamLaunchTarget(
            expectedRunnerPath: URL(fileURLWithPath: "/Applications/ForgePlay.app/Contents/Resources/Runners/ForgePlayRuntime/wine/bin/wine"),
            expectedPrefixPath: prefix,
            expectedSteamExecutablePath: prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
        )
        let snapshot = SteamLaunchProcessSnapshot(processes: [
            SteamLaunchObservedProcess(
                processID: 903,
                command: "/Applications/ForgePlay.app/Contents/Resources/Runners/ForgePlayRuntime/wine/bin/wine C:\\Program Files (x86)\\Steam\\steam.exe WINEPREFIX=\(prefix.path)-Other"
            )
        ])

        XCTAssertFalse(snapshot.containsExpectedPrefixSteamProcess(for: target))
        XCTAssertEqual(snapshot.steamOrWineProcessesOutsideTarget(for: target).map(\.processID), [903])
    }

    func testSteamLaunchProcessSnapshotAcceptsNativeWineLoaderPath() {
        let target = SteamLaunchTarget(
            expectedRunnerPath: URL(fileURLWithPath: "/Volumes/Runtime/ForgePlayRuntime/wine/bin/wine"),
            expectedPrefixPath: URL(fileURLWithPath: "/Volumes/Games/Prefixes/SteamShared"),
            expectedSteamExecutablePath: URL(fileURLWithPath: "/Volumes/Games/Prefixes/SteamShared/drive_c/Program Files (x86)/Steam/steam.exe")
        )
        let snapshot = SteamLaunchProcessSnapshot(processes: [
            SteamLaunchObservedProcess(
                processID: 601,
                command: "/Volumes/Runtime/ForgePlayRuntime/wine/lib/wine/x86_64-unix/wine C:\\Program Files (x86)\\Steam\\steam.exe WINEPREFIX=/Volumes/Games/Prefixes/SteamShared"
            ),
            SteamLaunchObservedProcess(
                processID: 602,
                command: "/Volumes/Runtime/ForgePlayRuntime/wine/lib/wine/x86_64-unix/wine C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win64\\steamwebhelper.exe --no-sandbox WINEPREFIX=/Volumes/Games/Prefixes/SteamShared"
            )
        ])

        XCTAssertTrue(snapshot.containsExpectedRunnerProcess(for: target))
        XCTAssertTrue(snapshot.containsExpectedPrefixSteamProcess(for: target))
        XCTAssertEqual(snapshot.webHelperCommandLines(for: target).map { $0.contains("PID 602") }, [true])
    }

    func testSteamLaunchScreenEvidenceRecognizesSteamQRCodeLoginText() {
        XCTAssertTrue(SteamLaunchDiagnosticsReporter.recognizesWindowsSteamUI(in: [
            "Steam",
            "the Steam Mobile App to sign",
            "in via QR code",
            "Create a Free Account"
        ]))
        XCTAssertTrue(
            SteamLaunchDiagnosticsReporter.recognizesWindowsSteamUI(
                in: ["STEAM", "QR"],
                containsQRCode: true
            ),
            "Localized Steam login screenshots remain verifiable when OCR sees the Steam brand but barcode detection supplies the QR-login evidence"
        )
        XCTAssertFalse(
            SteamLaunchDiagnosticsReporter.recognizesWindowsSteamUI(
                in: ["STEAM"],
                containsQRCode: false
            ),
            "The Steam logo alone must not satisfy visible UI conformance"
        )
        XCTAssertEqual(
            SteamLaunchDiagnosticsReporter.windowsSteamUISurface(
                in: ["STEAM", "QR"],
                containsQRCode: true
            ),
            .signIn
        )
        XCTAssertEqual(
            SteamLaunchDiagnosticsReporter.windowsSteamUISurface(
                in: ["Steam Guard", "Enter the code from your mobile authenticator"]
            ),
            .steamGuard
        )
        XCTAssertEqual(
            SteamLaunchDiagnosticsReporter.windowsSteamUISurface(
                in: ["STORE", "LIBRARY", "COMMUNITY"]
            ),
            .library
        )
        XCTAssertNil(
            SteamLaunchDiagnosticsReporter.windowsSteamUISurface(in: ["STEAM"])
        )
    }

    func testSteamLaunchScreenEvidencePreservesQRCodeDetectorFailure() {
        let screenshotURL = URL(fileURLWithPath: "/tmp/forgeplay-qr-detector-failure.png")
        let evidence = SteamLaunchDiagnosticsReporter.screenEvidenceAfterRecognition(
            screenshotURL: screenshotURL,
            recognizedText: ["STEAM"],
            qrCodeDetection: .failure(POSIXError(.EIO))
        )

        XCTAssertEqual(evidence.state, .recognitionFailed)
        XCTAssertFalse(evidence.verifiesWindowsSteamUI)
        XCTAssertEqual(evidence.recognizedText, ["STEAM"])
        XCTAssertTrue(evidence.message.contains("QR code detector failed"), evidence.message)
        XCTAssertTrue(evidence.message.contains("verification is unavailable"), evidence.message)
    }

    func testSteamUIConformanceMarkerBlocksWindowsSteamLaunches() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamConformanceMarker-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let runnerRoot = temporaryRoot.appending(path: "ForgePlayRuntime", directoryHint: .isDirectory)
        let launcherDirectory = runnerRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let wineRoot = runnerRoot.appending(path: "wine", directoryHint: .isDirectory)
        let renderer = runnerRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try writeD3DMetalRenderer(at: renderer)
        try """
        #!/bin/sh
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try """
        {
          "steam_ui_support": false,
          "steam_ui_status": "failed_known_bad",
          "control_note": "external control environment is not product evidence"
        }
        """.write(
            to: runnerRoot.appending(path: "STEAM-UI-CONFORMANCE.json"),
            atomically: true,
            encoding: .utf8
        )

        let capability = WindowsRuntimeService.inspectRuntimeCapability(for: launcher)
        let verification = SteamClientCompatibilityVerifier.verify(capability: capability)

        XCTAssertTrue(capability.hasKnownBadSteamUIConformance)
        XCTAssertTrue(capability.limitations.contains("steam-ui-failed-known-bad"))
        XCTAssertTrue(capability.evidence.contains("STEAM-UI-CONFORMANCE.json: steam_ui_status=failed_known_bad"))
        XCTAssertFalse(verification.canLaunchWindowsSteam)
        XCTAssertTrue(verification.launchBlockers.contains(.knownBadSteamUIConformance))
        XCTAssertTrue(WindowsRuntimeDisplayName.statusSummary(for: capability).contains("failed_known_bad"))
    }

    func testLaunchSteamBlocksKnownBadSteamUIConformanceBeforeStartingProcess() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamKnownBadRunner-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let runnerRoot = temporaryRoot.appending(path: "ForgePlayRuntime", directoryHint: .isDirectory)
        let launcherDirectory = runnerRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let wineRoot = runnerRoot.appending(path: "wine", directoryHint: .isDirectory)
        let renderer = runnerRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        let invocationLog = temporaryRoot.appending(path: "runner-invocation.log")
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try createSteamWindowsSystemDirectories(in: prefix)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try writeD3DMetalRenderer(at: renderer)
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try """
        {
          "steam_ui_support": false,
          "steam_ui_status": "failed_known_bad",
          "reason": "steam-crash-or-webhelper-not-observed"
        }
        """.write(
            to: runnerRoot.appending(path: "STEAM-UI-CONFORMANCE.json"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .conformance,
            rendererPolicy: .d3dMetal
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.processExitCode)
        XCTAssertEqual(result.forgePlayStatusCode, SteamManager.steamLaunchBlockedExitCode)
        let diagnosticLog = try XCTUnwrap(result.diagnosticLog)
        let diagnostics = try String(contentsOf: diagnosticLog, encoding: .utf8)
        XCTAssertTrue(diagnostics.contains("STATUS: BLOCKED"), diagnostics)
        XCTAssertTrue(diagnostics.contains("blocked-runner-preflight-failed"), diagnostics)
        XCTAssertTrue(diagnostics.contains("failed_known_bad"), diagnostics)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocationLog.path))
    }

    func testSteamLaunchArgumentsUseMinimalSteamClientProfileForD3DMetalPolicy() {
        let arguments = SteamClientCompatibilityProfile.launchArguments(for: .d3dMetal)

        XCTAssertEqual(arguments, [
            "-no-cef-sandbox"
        ])
        XCTAssertFalse(arguments.contains("-udpforce"))
        XCTAssertFalse(arguments.contains("-allosarches"))
        XCTAssertFalse(arguments.contains("-cef-force-32bit"))
        XCTAssertFalse(arguments.contains("-noreactlogin"))
        XCTAssertFalse(arguments.contains("-no-browser"))
        XCTAssertFalse(arguments.contains("+open"))
        XCTAssertFalse(arguments.contains("steam://open/minigameslist"))
        XCTAssertTrue(arguments.contains("-no-cef-sandbox"))
        XCTAssertFalse(arguments.contains("-cef-disable-gpu"))
        XCTAssertFalse(arguments.contains("-cef-in-process-gpu"))
        XCTAssertFalse(arguments.contains("-cef-disable-gpu-compositing"))
        XCTAssertFalse(arguments.contains("-cef-use-gl=angle"))
        XCTAssertFalse(arguments.contains("-cef-use-angle=d3d11"))
        XCTAssertFalse(arguments.contains("-cef-use-angle=vulkan"))
        XCTAssertFalse(arguments.contains("-cef-disable-software-rasterizer"))
        XCTAssertFalse(arguments.contains("-cef-disable-vulkan"))
        XCTAssertFalse(arguments.contains("-disable-vulkan"))
    }

    func testSteamLaunchArgumentsAreIndependentFromGameRendererPolicy() {
        let d3dMetalArguments = SteamClientCompatibilityProfile.launchArguments(for: .d3dMetal)
        let vulkanArguments = SteamClientCompatibilityProfile.launchArguments(for: .vulkan)

        XCTAssertEqual(d3dMetalArguments, vulkanArguments)
        XCTAssertFalse(vulkanArguments.contains("-cef-use-gl=angle"))
        XCTAssertFalse(vulkanArguments.contains("-cef-use-angle=vulkan"))
    }

    func testSteamInstallerValidationRejectsUnsafeFiles() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamInstallerRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let realInstaller = temporaryRoot.appending(path: "RealSteamSetup.exe")
        let linkedInstaller = temporaryRoot.appending(path: "SteamSetup.exe")
        let hardlinkFolder = temporaryRoot.appending(path: "HardlinkInstaller", directoryHint: .isDirectory)
        let hardlinkedInstaller = hardlinkFolder.appending(path: "SteamSetup.exe")
        try FileManager.default.createDirectory(at: hardlinkFolder, withIntermediateDirectories: true)
        try Data().write(to: realInstaller)
        try FileManager.default.createSymbolicLink(at: linkedInstaller, withDestinationURL: realInstaller)
        try FileManager.default.linkItem(at: realInstaller, to: hardlinkedInstaller)

        XCTAssertFalse(steamManager.validateSteamInstaller(linkedInstaller))
        XCTAssertFalse(steamManager.validateSteamInstaller(hardlinkedInstaller))
        for installer in [linkedInstaller, hardlinkedInstaller] {
            do {
                _ = try await steamManager.installSteam(
                    runtimeExecutable: temporaryRoot.appending(path: "wine"),
                    installer: installer,
                    language: .english
                )
                XCTFail("Expected unsafe Steam installer to be rejected")
            } catch SteamInstallError.invalidInstaller(let url) {
                XCTAssertEqual(url, installer)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMapsWineSteamLibraryPathsToMacPaths() {
        let prefix = URL(fileURLWithPath: "/Users/test/ForgePlay/Prefixes/SteamShared")

        XCTAssertEqual(
            SteamManager.macURL(fromSteamLibraryPath: #"C:\Program Files (x86)\Steam"#, prefix: prefix).path,
            "/Users/test/ForgePlay/Prefixes/SteamShared/drive_c/Program Files (x86)/Steam"
        )
        XCTAssertEqual(
            SteamManager.macURL(fromSteamLibraryPath: #"Z:\Volumes\ExternalSSD\SteamLibrary"#, prefix: prefix).path,
            "/Volumes/ExternalSSD/SteamLibrary"
        )
        XCTAssertEqual(
            SteamManager.macURL(fromSteamLibraryPath: "/Volumes/ExternalSSD/SteamLibrary", prefix: prefix).path,
            "/Volumes/ExternalSSD/SteamLibrary"
        )
    }

    func testValidatedWineSteamLibraryPathRejectsRootEscapeAndUnknownDrive() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayValidatedWinePath-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let prefix = temporaryRoot.appending(
            path: "Prefix",
            directoryHint: .isDirectory
        )
        let mappedRoot = temporaryRoot.appending(
            path: "Mapped",
            directoryHint: .isDirectory
        )
        let library = mappedRoot.appending(
            path: "SteamLibrary",
            directoryHint: .isDirectory
        )
        let dosdevices = prefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        for directory in [dosdevices, library] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createSymbolicLink(
            at: dosdevices.appending(path: "d:"),
            withDestinationURL: mappedRoot
        )

        XCTAssertEqual(
            SteamLibraryDriveMapper.validatedMacURL(
                fromSteamLibraryPath: #"D:\SteamLibrary"#,
                prefix: prefix
            ),
            library.standardizedFileURL
        )
        XCTAssertNil(
            SteamLibraryDriveMapper.validatedMacURL(
                fromSteamLibraryPath: #"D:\..\Outside"#,
                prefix: prefix
            )
        )
        XCTAssertNil(
            SteamLibraryDriveMapper.validatedMacURL(
                fromSteamLibraryPath: #"C:\..\Outside"#,
                prefix: prefix
            )
        )
        XCTAssertNil(
            SteamLibraryDriveMapper.validatedMacURL(
                fromSteamLibraryPath: #"Q:\SteamLibrary"#,
                prefix: prefix
            )
        )
    }

    func testScanSkipsMissingLibrariesFromLibraryFolders() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamScanRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let defaultLibrary = try pathManager.url(for: .defaultSteamLibrary)
        let steamapps = defaultLibrary.appending(path: "steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try """
        "libraryfolders"
        {
            "0"
            {
                "path" "\(temporaryRoot.appending(path: "MissingExternalLibrary").path)"
            }
        }
        """.write(to: steamapps.appending(path: "libraryfolders.vdf"), atomically: true, encoding: .utf8)

        let result = try steamManager.scanInstalledGamesResult()

        XCTAssertTrue(result.games.isEmpty)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(
            result.skippedInputPaths,
            [temporaryRoot.appending(path: "MissingExternalLibrary/steamapps").standardizedFileURL.path]
        )
    }

    func testScanSurfacesUnreadableSteamappsDirectory() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamScanRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let steamapps = try pathManager.url(for: .defaultSteamLibrary)
            .appending(path: "steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: steamapps.path)
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: steamapps.path)

        XCTAssertThrowsError(try steamManager.scanInstalledGames()) { error in
            guard let scanError = error as? SteamLibraryScanError,
                  case .scanFailed(let url, _) = scanError else {
                XCTFail("Expected SteamLibraryScanError.scanFailed, got \(error)")
                return
            }
            XCTAssertEqual(url.standardizedFileURL.path, steamapps.standardizedFileURL.path)
        }
    }

    func testScanSkipsSymlinkSteamappsDirectory() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamScanRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let defaultLibrary = try pathManager.url(for: .defaultSteamLibrary)
        let externalSteamapps = temporaryRoot.appending(path: "ExternalSteamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: externalSteamapps, withIntermediateDirectories: true)
        try writeManifest(
            appId: "777001",
            name: "Linked Library Game",
            installDir: "Linked Library Game",
            to: externalSteamapps.appending(path: "appmanifest_777001.acf")
        )
        try FileManager.default.createSymbolicLink(
            at: defaultLibrary.appending(path: "steamapps", directoryHint: .isDirectory),
            withDestinationURL: externalSteamapps
        )

        XCTAssertTrue(try steamManager.scanInstalledGames().isEmpty)
    }

    func testScanSkipsOversizedSteamManifest() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamScanRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let steamapps = try pathManager.url(for: .defaultSteamLibrary)
            .appending(path: "steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        let oversizedName = String(repeating: "A", count: 260 * 1024)
        try """
        "AppState"
        {
            "appid" "777002"
            "name" "\(oversizedName)"
            "installdir" "Oversized Manifest Game"
        }
        """.write(to: steamapps.appending(path: "appmanifest_777002.acf"), atomically: true, encoding: .utf8)

        let result = try steamManager.scanInstalledGamesResult()

        XCTAssertTrue(result.games.isEmpty)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(
            result.skippedInputPaths,
            [steamapps.appending(path: "appmanifest_777002.acf").standardizedFileURL.path]
        )
    }

    func testScanSkipsOversizedLibraryFoldersVDF() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamScanRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let defaultLibrary = try pathManager.url(for: .defaultSteamLibrary)
        let steamapps = defaultLibrary.appending(path: "steamapps", directoryHint: .isDirectory)
        let externalLibrary = temporaryRoot.appending(path: "ExternalLibrary", directoryHint: .isDirectory)
        let externalSteamapps = externalLibrary.appending(path: "steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalSteamapps, withIntermediateDirectories: true)
        try writeManifest(
            appId: "777003",
            name: "External Library Game",
            installDir: "External Library Game",
            to: externalSteamapps.appending(path: "appmanifest_777003.acf")
        )
        let padding = String(repeating: "A", count: 260 * 1024)
        try """
        "libraryfolders"
        {
            "0"
            {
                "path" "\(externalLibrary.path)"
                "label" "\(padding)"
            }
        }
        """.write(to: steamapps.appending(path: "libraryfolders.vdf"), atomically: true, encoding: .utf8)

        let result = try steamManager.scanInstalledGamesResult()

        XCTAssertTrue(result.games.isEmpty)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(
            result.skippedInputPaths,
            [steamapps.appending(path: "libraryfolders.vdf").standardizedFileURL.path]
        )
    }

    func testScanSkipsHardlinkedSteamVDFInputs() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamScanRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLibrary = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalLibrary-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            try? FileManager.default.removeItem(at: externalLibrary)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let defaultLibrary = try pathManager.url(for: .defaultSteamLibrary)
        let steamapps = defaultLibrary.appending(path: "steamapps", directoryHint: .isDirectory)
        let externalSteamapps = externalLibrary.appending(path: "steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalSteamapps, withIntermediateDirectories: true)
        let sourceLibraryFolders = temporaryRoot.appending(path: "source-libraryfolders.vdf")
        let hardlinkedLibraryFolders = steamapps.appending(path: "libraryfolders.vdf")
        let sourceManifest = temporaryRoot.appending(path: "source-appmanifest_777011.acf")
        let hardlinkedManifest = steamapps.appending(path: "appmanifest_777011.acf")
        try """
        "libraryfolders"
        {
            "0"
            {
                "path" "\(externalLibrary.path)"
            }
        }
        """.write(to: sourceLibraryFolders, atomically: true, encoding: .utf8)
        try writeManifest(
            appId: "777011",
            name: "Hardlinked Manifest Game",
            installDir: "Hardlinked Manifest Game",
            to: sourceManifest
        )
        try writeManifest(
            appId: "777012",
            name: "External Library Game",
            installDir: "External Library Game",
            to: externalSteamapps.appending(path: "appmanifest_777012.acf")
        )
        try FileManager.default.linkItem(at: sourceLibraryFolders, to: hardlinkedLibraryFolders)
        try FileManager.default.linkItem(at: sourceManifest, to: hardlinkedManifest)

        let result = try steamManager.scanInstalledGamesResult()

        XCTAssertTrue(result.games.isEmpty)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(
            result.skippedInputPaths,
            Set([hardlinkedLibraryFolders, hardlinkedManifest].map { $0.standardizedFileURL.path })
        )
    }

    func testScanDoesNotFollowSymlinkSteamAppsDirectoryForLibraryFoldersOrManifests() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamScanRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        let symlinkTarget = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySymlinkSteamAppsTarget-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLibrary = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalLibrary-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            try? FileManager.default.removeItem(at: symlinkTarget)
            try? FileManager.default.removeItem(at: externalLibrary)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let defaultLibrary = try pathManager.url(for: .defaultSteamLibrary)
        let linkedSteamapps = defaultLibrary.appending(path: "steamapps", directoryHint: .isDirectory)
        let externalSteamapps = externalLibrary.appending(path: "steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: symlinkTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalSteamapps, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedSteamapps, withDestinationURL: symlinkTarget)
        try """
        "libraryfolders"
        {
            "0"
            {
                "path" "\(externalLibrary.path)"
            }
        }
        """.write(to: symlinkTarget.appending(path: "libraryfolders.vdf"), atomically: true, encoding: .utf8)
        try writeManifest(
            appId: "777013",
            name: "External Symlink SteamApps Game",
            installDir: "External Symlink SteamApps Game",
            to: externalSteamapps.appending(path: "appmanifest_777013.acf")
        )
        try writeManifest(
            appId: "777014",
            name: "Symlink SteamApps Manifest Game",
            installDir: "Symlink SteamApps Manifest Game",
            to: symlinkTarget.appending(path: "appmanifest_777014.acf")
        )

        XCTAssertTrue(try steamManager.scanInstalledGames().isEmpty)
    }

    func testScanSurfacesNonUTF8LibraryFoldersVDF() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamScanRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let steamapps = try pathManager.url(for: .defaultSteamLibrary)
            .appending(path: "steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        let libraryFolders = steamapps.appending(path: "libraryfolders.vdf")
        try Data([0xFF, 0xFE, 0x00]).write(to: libraryFolders)

        XCTAssertThrowsError(try steamManager.scanInstalledGames()) { error in
            guard let scanError = error as? SteamLibraryScanError,
                  case .fileReadFailed(let url, let message) = scanError else {
                XCTFail("Expected SteamLibraryScanError.fileReadFailed, got \(error)")
                return
            }
            XCTAssertEqual(url.standardizedFileURL.path, libraryFolders.standardizedFileURL.path)
            XCTAssertEqual(message, "invalid UTF-8 text")
        }
    }

    func testScanSurfacesNonUTF8SteamManifest() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamScanRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let steamapps = try pathManager.url(for: .defaultSteamLibrary)
            .appending(path: "steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        let manifest = steamapps.appending(path: "appmanifest_777009.acf")
        try Data([0xFF, 0xFE, 0x00]).write(to: manifest)

        XCTAssertThrowsError(try steamManager.scanInstalledGames()) { error in
            guard let scanError = error as? SteamLibraryScanError,
                  case .fileReadFailed(let url, let message) = scanError else {
                XCTFail("Expected SteamLibraryScanError.fileReadFailed, got \(error)")
                return
            }
            XCTAssertEqual(url.standardizedFileURL.path, manifest.standardizedFileURL.path)
            XCTAssertEqual(message, "invalid UTF-8 text")
        }
    }

    func testScanRejectsUnsafeManifestIdentityFields() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamScanRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let steamapps = try pathManager.url(for: .defaultSteamLibrary)
            .appending(path: "steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try writeManifest(
            appId: "../777004",
            name: "Unsafe App ID",
            installDir: "Unsafe App ID",
            to: steamapps.appending(path: "appmanifest_777004.acf")
        )
        try writeManifest(
            appId: "777005",
            name: "Mismatched App ID",
            installDir: "Mismatched App ID",
            to: steamapps.appending(path: "appmanifest_777999.acf")
        )
        try writeManifest(
            appId: "777006",
            name: "Escaped Install Dir",
            installDir: "../Escaped Install Dir",
            to: steamapps.appending(path: "appmanifest_777006.acf")
        )

        XCTAssertTrue(try steamManager.scanInstalledGames().isEmpty)
    }

    func testScanSurfacesMalformedSteamManifest() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamScanRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let steamapps = try pathManager.url(for: .defaultSteamLibrary)
            .appending(path: "steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try """
        "AppState"
        {
            "appid" "777008"
            "name" "Broken Manifest"
            "installdir" "Broken Manifest"
        """.write(to: steamapps.appending(path: "appmanifest_777008.acf"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try steamManager.scanInstalledGames()) { error in
            XCTAssertTrue(error is VDFParserError, "Expected VDFParserError, got \(error)")
        }
    }

    func testScanSurfacesUnterminatedQuotedSteamManifestString() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamScanRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let steamapps = try pathManager.url(for: .defaultSteamLibrary)
            .appending(path: "steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try #"""
        "AppState"
        {
            "appid" "777010"
            "name" "Unterminated Manifest
        """#.write(to: steamapps.appending(path: "appmanifest_777010.acf"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try steamManager.scanInstalledGames()) { error in
            XCTAssertEqual(error as? VDFParserError, .unexpectedEnd)
        }
    }

    func testScanNormalizesSafeManifestFieldWhitespace() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamScanRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let steamapps = try pathManager.url(for: .defaultSteamLibrary)
            .appending(path: "steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try writeManifest(
            appId: " 777007 ",
            name: " Trimmed Game ",
            installDir: " Trimmed Game ",
            to: steamapps.appending(path: "appmanifest_777007.acf")
        )

        let games = try steamManager.scanInstalledGames()

        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games.first?.steamAppId, "777007")
        XCTAssertEqual(games.first?.name, "Trimmed Game")
        XCTAssertEqual(games.first?.installDir, "Trimmed Game")
    }

    func testScanSkipsPartialManifestAndMissingInstallDirectory() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamInstallStateScan-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let steamapps = try pathManager.url(for: .defaultSteamLibrary)
            .appending(path: "steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try writeManifest(
            appId: "777020",
            name: "Partial Game",
            installDir: "Partial Game",
            stateFlags: 2,
            to: steamapps.appending(path: "appmanifest_777020.acf")
        )
        try writeManifest(
            appId: "777021",
            name: "Missing Payload Game",
            installDir: "Missing Payload Game",
            createsInstallDirectory: false,
            to: steamapps.appending(path: "appmanifest_777021.acf")
        )

        XCTAssertTrue(try steamManager.scanInstalledGames().isEmpty)
    }

    func testScanDeduplicatesAppIDUsingNewestInstalledManifest() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamDuplicateScan-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let defaultLibrary = try pathManager.url(for: .defaultSteamLibrary)
        let defaultSteamapps = defaultLibrary.appending(path: "steamapps", directoryHint: .isDirectory)
        let externalLibrary = temporaryRoot.appending(path: "ExternalLibrary", directoryHint: .isDirectory)
        let externalSteamapps = externalLibrary.appending(path: "steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: defaultSteamapps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalSteamapps, withIntermediateDirectories: true)
        try """
        "libraryfolders"
        {
            "1" { "path" "\(externalLibrary.path)" }
        }
        """.write(
            to: defaultSteamapps.appending(path: "libraryfolders.vdf"),
            atomically: true,
            encoding: .utf8
        )
        try writeManifest(
            appId: "777022",
            name: "Older Install",
            installDir: "Older Install",
            lastUpdated: 1_700_000_000,
            to: defaultSteamapps.appending(path: "appmanifest_777022.acf")
        )
        try writeManifest(
            appId: "777022",
            name: "Newer Install",
            installDir: "Newer Install",
            lastUpdated: 1_800_000_000,
            to: externalSteamapps.appending(path: "appmanifest_777022.acf")
        )

        let games = try steamManager.scanInstalledGames()

        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games.first?.name, "Newer Install")
        XCTAssertEqual(games.first?.libraryPath, externalLibrary.path)
    }

    func testGameReferenceReconciliationPreservesStaleRecordsUntilCompleteScan() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        context.insert(
            SteamGameRecord(
                steamAppId: "100",
                name: "Current",
                installDir: "Current",
                libraryPath: "/Library",
                manifestPath: "/Library/steamapps/appmanifest_100.acf"
            )
        )
        context.insert(
            SteamGameRecord(
                steamAppId: "200",
                name: "Temporarily Unavailable",
                installDir: "Unavailable",
                libraryPath: "/External",
                manifestPath: "/External/steamapps/appmanifest_200.acf"
            )
        )
        try context.save()
        let scannedGame = SteamGame(
            steamAppId: "100",
            name: "Current Updated",
            installDir: "Current",
            libraryPath: "/Library",
            manifestPath: "/Library/steamapps/appmanifest_100.acf",
            sizeOnDisk: 8,
            lastUpdated: nil
        )

        let partialScan = SteamLibraryScanResult(
            games: [scannedGame],
            skippedInputPaths: ["/External/steamapps/appmanifest_200.acf"]
        )
        let partialResult = try context.reconcileSteamGameReferences(
            partialScan.games,
            removesStaleRecords: partialScan.allowsRemovingStaleReferences(
                whenStorageAccessIsComplete: true
            )
        )
        XCTAssertEqual(partialResult.removedCount, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SteamGameRecord>()).count, 2)

        let completeScan = SteamLibraryScanResult(
            games: [scannedGame],
            skippedInputPaths: []
        )
        let completeResult = try context.reconcileSteamGameReferences(
            completeScan.games,
            removesStaleRecords: completeScan.allowsRemovingStaleReferences(
                whenStorageAccessIsComplete: true
            )
        )
        XCTAssertEqual(completeResult.removedCount, 1)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<SteamGameRecord>()).map(\.steamAppId),
            ["100"]
        )
    }

    func testLibraryRootCandidateNormalizesSteamCommonGameFolder() {
        let game = SteamGame(
            steamAppId: "524220",
            name: "NieR:Automata",
            installDir: "NieRAutomata",
            libraryPath: "/Volumes/Games/SteamLibrary/steamapps/common/NieRAutomata",
            manifestPath: "/Volumes/Games/SteamLibrary/steamapps/appmanifest_524220.acf",
            sizeOnDisk: 42,
            lastUpdated: nil
        )

        let libraryRoot = SteamManager.libraryRootCandidate(from: game)

        XCTAssertEqual(libraryRoot.path, "/Volumes/Games/SteamLibrary")
    }

    func testNormalizedLibraryRootsFindsSteamLibraryBelowSelectedVolumeRoot() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySelectedVolume-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let library = root.appending(
            path: "SteamLibrary",
            directoryHint: .isDirectory
        )
        let unrelated = root.appending(
            path: "Documents",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: library.appending(path: "steamapps", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: unrelated,
            withIntermediateDirectories: true
        )

        let pathManager = PathManager()
        let steamManager = makeSteamManager(pathManager: pathManager)

        XCTAssertEqual(
            steamManager.normalizedLibraryRoots(for: root),
            [library.standardizedFileURL]
        )
    }

    func testPersistedExternalVolumeLibrarySurvivesFreshReadbackRegistrationAndProcessGrant() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayExternalLibraryReadback-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let selectedVolume = fixtureRoot.appending(
            path: "SelectedVolume",
            directoryHint: .isDirectory
        )
        let canonicalLibrary = selectedVolume.appending(
            path: "SteamLibrary",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: canonicalLibrary.appending(
                path: "steamapps",
                directoryHint: .isDirectory
            ),
            withIntermediateDirectories: true
        )
        let libraryContentID = "8254199796506668567"
        try writeSteamLibraryFolderIdentity(
            contentID: libraryContentID,
            to: canonicalLibrary
        )

        let pathManager = PathManager()
        try pathManager.configureRoot(
            fixtureRoot.appending(path: "Managed", directoryHint: .isDirectory)
        )
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let steamApps = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: prefix.appending(path: "dosdevices", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: steamApps,
            withIntermediateDirectories: true
        )
        try """
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
        }
        """.write(
            to: steamApps.appending(path: "libraryfolders.vdf"),
            atomically: true,
            encoding: .utf8
        )

        let container = try ForgePlayApp.makeModelContainer(
            isStoredInMemoryOnly: true
        )
        let writeContext = ModelContext(container)
        let bookmark = Data("selected-volume-bookmark".utf8)
        _ = try writeContext.upsertSteamStorageMount(
            url: selectedVolume,
            bookmark: bookmark
        )
        try writeContext.save()

        func restore(
            state: AppState,
            context: ModelContext
        ) throws -> SteamLibraryAccessRestoration {
            try state.restorePersistedSteamStorageAccess(
                in: context,
                allowsPathFallback: false,
                bookmarkResolver: { data in
                    XCTAssertEqual(data, bookmark)
                    return SecurityScopedBookmarkResolvedURL(
                        url: selectedVolume,
                        isStale: false
                    )
                },
                securityScopeStarter: { url in
                    XCTAssertEqual(
                        url.standardizedFileURL,
                        selectedVolume.standardizedFileURL
                    )
                    return true
                }
            )
        }

        let firstState = AppState()
        let firstAccess = try restore(
            state: firstState,
            context: ModelContext(container)
        )
        XCTAssertEqual(firstAccess.roots, [selectedVolume.standardizedFileURL])
        let firstManager = makeSteamManager(pathManager: pathManager)
        let firstPreparation = try firstManager
            .prepareSteamLibraryDriveLinksWithEvidence(
                prefix: prefix,
                libraryRoots: firstAccess.roots,
                reservedLibraryRoots: firstAccess.driveReservationRoots
            )
        XCTAssertEqual(
            firstPreparation.discoveries.map(\.resolution),
            [.immediateChildLibraries]
        )
        let firstMapping = try XCTUnwrap(firstPreparation.mappings.first)
        XCTAssertEqual(firstMapping.macDriveRootURL, selectedVolume)
        XCTAssertEqual(firstMapping.macLibraryURL, canonicalLibrary)
        XCTAssertEqual(firstMapping.windowsLibraryPath, "D:\\SteamLibrary")
        try firstManager.synchronizeSteamLibraryRegistrations(
            prefix: prefix,
            mappings: firstPreparation.mappings,
            discoveries: firstPreparation.discoveries
        )
        firstState.releaseAllSecurityScopedAccess()

        let secondState = AppState()
        defer { secondState.releaseAllSecurityScopedAccess() }
        let secondAccess = try restore(
            state: secondState,
            context: ModelContext(container)
        )
        let secondManager = makeSteamManager(pathManager: pathManager)
        let secondPreparation = try secondManager
            .prepareSteamLibraryDriveLinksWithEvidence(
                prefix: prefix,
                libraryRoots: secondAccess.roots,
                reservedLibraryRoots: secondAccess.driveReservationRoots
            )
        let secondMapping = try XCTUnwrap(secondPreparation.mappings.first)
        XCTAssertEqual(secondMapping.driveLetter, firstMapping.driveLetter)
        XCTAssertEqual(secondMapping.macDriveRootURL, selectedVolume)
        XCTAssertEqual(secondMapping.macLibraryURL, canonicalLibrary)
        XCTAssertEqual(secondMapping.windowsLibraryPath, "D:\\SteamLibrary")
        try secondManager.synchronizeSteamLibraryRegistrations(
            prefix: prefix,
            mappings: secondPreparation.mappings,
            discoveries: secondPreparation.discoveries
        )

        let registeredText = try XCTUnwrap(
            try SteamVDFFileReader.readText(
                steamApps.appending(path: "libraryfolders.vdf"),
                maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes
            )
        )
        let registeredFolders = try XCTUnwrap(
            VDFParser().parse(registeredText)["libraryfolders"]?.objectValue
        )
        XCTAssertEqual(
            registeredFolders.values.compactMap {
                $0.objectValue?["path"]?.stringValue
            }.filter { $0 == "D:\\SteamLibrary" }.count,
            1
        )
        XCTAssertEqual(
            registeredFolders.values.first {
                $0.objectValue?["path"]?.stringValue == "D:\\SteamLibrary"
            }?.objectValue?["contentid"]?.stringValue,
            libraryContentID
        )

        let applicationGroupContainer = fixtureRoot.appending(
            path: "ApplicationGroup",
            directoryHint: .isDirectory
        )
        let bridge = fixtureRoot.appending(path: "ExternalStorageBridge.dylib")
        try FileManager.default.createDirectory(
            at: applicationGroupContainer,
            withIntermediateDirectories: true
        )
        try Data("bridge".utf8).write(to: bridge)
        let publisher = SteamExternalStorageProcessGrantPublisher(
            fileManager: .default,
            applicationGroupContainerURLProvider: {
                applicationGroupContainer
            },
            bridgeURLProvider: { bridge },
            bookmarkDataProvider: { url in
                Data("process-bookmark:\(url.path)".utf8)
            }
        )
        let grant = try publisher.publish(
            roots: secondPreparation.externalStorageRoots,
            prefix: prefix,
            runIdentifier: UUID().uuidString
        )
        let grantDocument = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: grant.manifestURL)
            ) as? [String: Any]
        )
        let grantEntries = try XCTUnwrap(
            grantDocument["entries"] as? [[String: Any]]
        )
        XCTAssertEqual(
            grantEntries.compactMap { $0["canonical_path"] as? String },
            [selectedVolume.resolvingSymlinksInPath().path]
        )
    }

    func testPersistedBlankExternalStorageMapsAndGrantsBeforeSteamCreatesLibraryThenPromotesOnReadback() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayBlankExternalStorage-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let selectedVolume = fixtureRoot.appending(
            path: "SelectedVolume",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: selectedVolume,
            withIntermediateDirectories: true
        )

        let pathManager = PathManager()
        try pathManager.configureRoot(
            fixtureRoot.appending(path: "Managed", directoryHint: .isDirectory)
        )
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        let steamApps = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: dosdevices,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: steamApps,
            withIntermediateDirectories: true
        )
        let initialLibraryFolders = """
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
        }
        """
        let libraryFoldersURL = steamApps.appending(
            path: "libraryfolders.vdf",
            directoryHint: .notDirectory
        )
        try initialLibraryFolders.write(
            to: libraryFoldersURL,
            atomically: true,
            encoding: .utf8
        )

        let container = try ForgePlayApp.makeModelContainer(
            isStoredInMemoryOnly: true
        )
        let bookmark = Data("blank-volume-bookmark".utf8)
        let writeContext = ModelContext(container)
        _ = try writeContext.upsertSteamStorageMount(
            url: selectedVolume,
            bookmark: bookmark
        )
        try writeContext.save()

        func restore(
            state: AppState
        ) throws -> SteamLibraryAccessRestoration {
            try state.restorePersistedSteamStorageAccess(
                in: ModelContext(container),
                allowsPathFallback: false,
                bookmarkResolver: { data in
                    XCTAssertEqual(data, bookmark)
                    return SecurityScopedBookmarkResolvedURL(
                        url: selectedVolume,
                        isStale: false
                    )
                },
                securityScopeStarter: { url in
                    XCTAssertEqual(
                        url.standardizedFileURL,
                        selectedVolume.standardizedFileURL
                    )
                    return true
                }
            )
        }

        let firstState = AppState()
        let firstAccess = try restore(state: firstState)
        let firstManager = makeSteamManager(pathManager: pathManager)
        let firstPreparation = try firstManager
            .prepareSteamLibraryDriveLinksWithEvidence(
                prefix: prefix,
                libraryRoots: firstAccess.roots,
                reservedLibraryRoots: firstAccess.driveReservationRoots
        )
        XCTAssertTrue(firstPreparation.mappings.isEmpty)
        XCTAssertTrue(firstPreparation.pendingMappings.isEmpty)
        XCTAssertEqual(
            firstPreparation.externalStorageRoots,
            [selectedVolume.standardizedFileURL]
        )
        XCTAssertEqual(firstPreparation.discoveries.count, 1)
        guard case .noVerifiedSteamLibrary? =
                firstPreparation.discoveries.first?.failure else {
            return XCTFail("Expected blank-storage discovery state")
        }
        let firstDriveTarget = try FileManager.default
            .destinationOfSymbolicLink(
                atPath: dosdevices.appending(path: "d:").path
            )
        XCTAssertEqual(
            URL(fileURLWithPath: firstDriveTarget, isDirectory: true)
                .standardizedFileURL.path,
            selectedVolume.standardizedFileURL.path
        )
        XCTAssertEqual(
            SteamManager.mappedWindowsLibraryPath(
                for: selectedVolume,
                prefix: prefix
            ),
            "D:\\"
        )
        try firstManager.synchronizeSteamLibraryRegistrations(
            prefix: prefix,
            mappings: firstPreparation.mappings,
            discoveries: firstPreparation.discoveries
        )
        XCTAssertEqual(
            try String(contentsOf: libraryFoldersURL, encoding: .utf8),
            initialLibraryFolders
        )

        let applicationGroupContainer = fixtureRoot.appending(
            path: "ApplicationGroup",
            directoryHint: .isDirectory
        )
        let bridge = fixtureRoot.appending(path: "ExternalStorageBridge.dylib")
        try FileManager.default.createDirectory(
            at: applicationGroupContainer,
            withIntermediateDirectories: true
        )
        try Data("bridge".utf8).write(to: bridge)
        let publisher = SteamExternalStorageProcessGrantPublisher(
            fileManager: .default,
            applicationGroupContainerURLProvider: {
                applicationGroupContainer
            },
            bridgeURLProvider: { bridge },
            bookmarkDataProvider: { url in
                Data("process-bookmark:\(url.path)".utf8)
            }
        )
        let firstGrant = try publisher.publish(
            roots: firstPreparation.externalStorageRoots,
            prefix: prefix,
            runIdentifier: UUID().uuidString
        )
        let firstGrantDocument = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: firstGrant.manifestURL)
            ) as? [String: Any]
        )
        let firstGrantEntries = try XCTUnwrap(
            firstGrantDocument["entries"] as? [[String: Any]]
        )
        XCTAssertEqual(
            firstGrantEntries.compactMap { $0["canonical_path"] as? String },
            [selectedVolume.resolvingSymlinksInPath().path]
        )
        firstState.releaseAllSecurityScopedAccess()

        // Simulate Steam, not ForgePlay, creating the library through its
        // Storage UI while the blank authorized drive is exposed as D:.
        let steamCreatedLibrary = selectedVolume.appending(
            path: "SteamLibrary",
            directoryHint: .isDirectory
        )
        let steamCreatedApps = steamCreatedLibrary.appending(
            path: "steamapps",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: steamCreatedApps,
            withIntermediateDirectories: true
        )
        try Data().write(
            to: steamCreatedLibrary.appending(path: "libraryfolder.vdf")
        )
        let partialState = AppState()
        let partialAccess = try restore(state: partialState)
        let partialPreparation = try firstManager
            .prepareSteamLibraryDriveLinksWithEvidence(
                prefix: prefix,
                libraryRoots: partialAccess.roots,
                reservedLibraryRoots: partialAccess.driveReservationRoots
            )
        XCTAssertTrue(partialPreparation.mappings.isEmpty)
        XCTAssertEqual(
            partialPreparation.externalStorageRoots,
            [selectedVolume.standardizedFileURL]
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: dosdevices.appending(path: "d:").path
            ),
            selectedVolume.standardizedFileURL.path
        )
        _ = try publisher.publish(
            roots: partialPreparation.externalStorageRoots,
            prefix: prefix,
            runIdentifier: UUID().uuidString
        )
        partialState.releaseAllSecurityScopedAccess()

        let contentID = "6198427214108100536"
        try writeSteamLibraryFolderIdentity(
            contentID: contentID,
            label: "Steam-owned external",
            to: steamCreatedLibrary
        )
        try writeManifest(
            appId: "990001",
            name: "Blank Storage Fixture",
            installDir: "BlankStorageFixture",
            to: steamCreatedApps.appending(path: "appmanifest_990001.acf")
        )
        let steamOwnedLibraryFolders = """
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
            "1"
            {
                "path" "D:\\\\SteamLibrary"
                "label" "Steam-owned external"
                "contentid" "\(contentID)"
                "totalsize" "4000000000000"
                "update_clean_bytes_tally" "17"
                "apps" { "990001" "8" }
            }
        }
        """
        try steamOwnedLibraryFolders.write(
            to: libraryFoldersURL,
            atomically: true,
            encoding: .utf8
        )

        let secondState = AppState()
        defer { secondState.releaseAllSecurityScopedAccess() }
        let secondAccess = try restore(state: secondState)
        let secondManager = makeSteamManager(pathManager: pathManager)
        let secondPreparation = try secondManager
            .prepareSteamLibraryDriveLinksWithEvidence(
                prefix: prefix,
                libraryRoots: secondAccess.roots,
                reservedLibraryRoots: secondAccess.driveReservationRoots
            )
        XCTAssertEqual(
            secondPreparation.externalStorageRoots,
            [selectedVolume.standardizedFileURL]
        )
        let promotedMapping = try XCTUnwrap(secondPreparation.mappings.first)
        XCTAssertEqual(secondPreparation.mappings.count, 1)
        XCTAssertTrue(secondPreparation.pendingMappings.isEmpty)
        XCTAssertEqual(promotedMapping.driveLetter, "d")
        XCTAssertEqual(promotedMapping.macDriveRootURL, selectedVolume)
        XCTAssertEqual(promotedMapping.macLibraryURL, steamCreatedLibrary)
        XCTAssertEqual(promotedMapping.windowsLibraryPath, "D:\\SteamLibrary")
        try secondManager.synchronizeSteamLibraryRegistrations(
            prefix: prefix,
            mappings: secondPreparation.mappings,
            discoveries: secondPreparation.discoveries
        )

        let readbackText = try XCTUnwrap(
            try SteamVDFFileReader.readText(
                libraryFoldersURL,
                maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes
            )
        )
        let readbackFolders = try XCTUnwrap(
            VDFParser().parse(readbackText)["libraryfolders"]?.objectValue
        )
        let steamOwnedEntry = try XCTUnwrap(
            readbackFolders.values.first {
                $0.objectValue?["path"]?.stringValue == "D:\\SteamLibrary"
            }?.objectValue
        )
        XCTAssertEqual(steamOwnedEntry["contentid"]?.stringValue, contentID)
        XCTAssertEqual(
            steamOwnedEntry["label"]?.stringValue,
            "Steam-owned external"
        )
        XCTAssertEqual(
            steamOwnedEntry["totalsize"]?.stringValue,
            "4000000000000"
        )
        XCTAssertEqual(
            steamOwnedEntry["update_clean_bytes_tally"]?.stringValue,
            "17"
        )
        XCTAssertEqual(
            steamOwnedEntry["apps"]?.objectValue?["990001"]?.stringValue,
            "8"
        )

        let games = try secondManager.linkedGamesFromUserSelection(
            selectedVolume
        )
        XCTAssertEqual(games.map(\.steamAppId), ["990001"])
        XCTAssertEqual(games.map(\.name), ["Blank Storage Fixture"])
    }

    func testPendingSteamLibraryIdentityPreservesOwnedRegistrationUntilValidReadback() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayPendingSteamLibraryIdentity-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let selectedVolume = fixtureRoot.appending(
            path: "SelectedVolume",
            directoryHint: .isDirectory
        )
        let library = selectedVolume.appending(
            path: "SteamLibrary",
            directoryHint: .isDirectory
        )
        let librarySteamApps = library.appending(
            path: "steamapps",
            directoryHint: .isDirectory
        )

        let pathManager = PathManager()
        try pathManager.configureRoot(
            fixtureRoot.appending(path: "Managed", directoryHint: .isDirectory)
        )
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        let steamApps = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        for directory in [dosdevices, librarySteamApps, steamApps] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let firstContentID = "7300000000000000001"
        try writeSteamLibraryFolderIdentity(
            contentID: firstContentID,
            to: library
        )
        let libraryFoldersURL = steamApps.appending(
            path: "libraryfolders.vdf",
            directoryHint: .notDirectory
        )
        try """
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
        }
        """.write(
            to: libraryFoldersURL,
            atomically: true,
            encoding: .utf8
        )

        let manager = makeSteamManager(pathManager: pathManager)
        let initial = try manager.prepareSteamLibraryDriveLinksWithEvidence(
            prefix: prefix,
            libraryRoots: [selectedVolume]
        )
        XCTAssertEqual(initial.mappings.count, 1)
        XCTAssertTrue(initial.pendingMappings.isEmpty)
        try manager.synchronizeSteamLibraryRegistrations(
            prefix: prefix,
            mappings: initial.mappings,
            pendingMappings: initial.pendingMappings
        )

        let registrationManifestURL = prefix.appending(
            path: ".forgeplay-library-drives/.steam-library-registrations-v1.json",
            directoryHint: .notDirectory
        )
        let ownedLibraryFolders = try Data(contentsOf: libraryFoldersURL)
        let ownedManifest = try Data(contentsOf: registrationManifestURL)

        // Simulate Steam being interrupted while replacing its identity marker.
        // The drive and process-grant root remain active, while registration is
        // held pending without mutating either owned persistence file.
        try Data(#""libraryfolder" { "contentid" ""#.utf8).write(
            to: library.appending(path: "libraryfolder.vdf")
        )
        let pending = try manager.prepareSteamLibraryDriveLinksWithEvidence(
            prefix: prefix,
            libraryRoots: [selectedVolume]
        )
        XCTAssertTrue(pending.mappings.isEmpty)
        XCTAssertEqual(pending.pendingMappings.count, 1)
        XCTAssertEqual(
            pending.pendingMappings.first?.windowsLibraryPath,
            "D:\\SteamLibrary"
        )
        XCTAssertEqual(
            pending.externalStorageRoots,
            [selectedVolume.standardizedFileURL]
        )
        let pendingDriveTarget = try FileManager.default
            .destinationOfSymbolicLink(
                atPath: dosdevices.appending(path: "d:").path
            )
        XCTAssertEqual(
            URL(fileURLWithPath: pendingDriveTarget, isDirectory: true)
                .standardizedFileURL.path,
            selectedVolume.standardizedFileURL.path
        )
        try manager.synchronizeSteamLibraryRegistrations(
            prefix: prefix,
            mappings: pending.mappings,
            pendingMappings: pending.pendingMappings
        )
        XCTAssertEqual(try Data(contentsOf: libraryFoldersURL), ownedLibraryFolders)
        XCTAssertEqual(try Data(contentsOf: registrationManifestURL), ownedManifest)

        let promotedContentID = "7300000000000000002"
        try writeSteamLibraryFolderIdentity(
            contentID: promotedContentID,
            to: library
        )
        let promoted = try manager.prepareSteamLibraryDriveLinksWithEvidence(
            prefix: prefix,
            libraryRoots: [selectedVolume]
        )
        XCTAssertEqual(promoted.mappings.count, 1)
        XCTAssertTrue(promoted.pendingMappings.isEmpty)
        XCTAssertEqual(promoted.mappings.first?.driveLetter, "d")
        try manager.synchronizeSteamLibraryRegistrations(
            prefix: prefix,
            mappings: promoted.mappings,
            pendingMappings: promoted.pendingMappings
        )

        let promotedFolders = try XCTUnwrap(
            VDFParser().parse(
                try XCTUnwrap(
                    SteamVDFFileReader.readText(
                        libraryFoldersURL,
                        maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes
                    )
                )
            )["libraryfolders"]?.objectValue
        )
        XCTAssertEqual(
            promotedFolders.values.first {
                $0.objectValue?["path"]?.stringValue == "D:\\SteamLibrary"
            }?.objectValue?["contentid"]?.stringValue,
            promotedContentID
        )
        let promotedManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: registrationManifestURL)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            (promotedManifest["ownedRegistrations"] as? [[String: Any]])?
                .first?["contentID"] as? String,
            promotedContentID
        )
    }

    func testExactSteamOwnedLibraryRegistrationIsByteStableNoOp() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamOwnedRegistrationNoOp-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let selectedVolume = fixtureRoot.appending(
            path: "SelectedVolume",
            directoryHint: .isDirectory
        )
        let library = selectedVolume.appending(
            path: "SteamLibrary",
            directoryHint: .isDirectory
        )
        let pathManager = PathManager()
        try pathManager.configureRoot(
            fixtureRoot.appending(path: "Managed", directoryHint: .isDirectory)
        )
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let steamApps = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        for directory in [
            prefix.appending(path: "dosdevices", directoryHint: .isDirectory),
            library.appending(path: "steamapps", directoryHint: .isDirectory),
            steamApps
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let contentID = "7400000000000000001"
        try writeSteamLibraryFolderIdentity(contentID: contentID, to: library)
        let libraryFoldersURL = steamApps.appending(
            path: "libraryfolders.vdf",
            directoryHint: .notDirectory
        )
        let steamOwnedBytes = Data("""
        // Steam owns this entry and its formatting.
        "libraryfolders" {
          "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
          "9" {
            "path" "D:\\\\SteamLibrary"
            "label" "Steam exact"
            "contentid" "\(contentID)"
            "totalsize" "4000000000000"
            "apps" { "990002" "17" }
          }
        }
        """.utf8)
        try steamOwnedBytes.write(to: libraryFoldersURL)

        let manager = makeSteamManager(pathManager: pathManager)
        let preparation = try manager.prepareSteamLibraryDriveLinksWithEvidence(
            prefix: prefix,
            libraryRoots: [selectedVolume]
        )
        XCTAssertEqual(preparation.mappings.count, 1)
        XCTAssertTrue(preparation.pendingMappings.isEmpty)
        let registrationManifestURL = prefix.appending(
            path: ".forgeplay-library-drives/.steam-library-registrations-v1.json",
            directoryHint: .notDirectory
        )
        let emptyManifestBytes = Data("""
        {
          "ownedRegistrations" : [ ],
          "version" : 3
        }
        """.utf8)
        try emptyManifestBytes.write(to: registrationManifestURL)

        try manager.synchronizeSteamLibraryRegistrations(
            prefix: prefix,
            mappings: preparation.mappings,
            pendingMappings: preparation.pendingMappings
        )

        XCTAssertEqual(try Data(contentsOf: libraryFoldersURL), steamOwnedBytes)
        XCTAssertEqual(
            try Data(contentsOf: registrationManifestURL),
            emptyManifestBytes
        )
    }

    func testOwnedRegistrationDivergenceAcrossSteamCopiesRelinquishesWithoutVDFMutation()
        throws
    {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayRegistrationCopyDivergence-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let prefix = fixtureRoot.appending(
            path: "Prefix",
            directoryHint: .isDirectory
        )
        let externalLibrary = fixtureRoot.appending(
            path: "External/SteamLibrary",
            directoryHint: .isDirectory
        )
        let steamDirectory = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        let steamApps = steamDirectory.appending(
            path: "steamapps",
            directoryHint: .isDirectory
        )
        let config = steamDirectory.appending(
            path: "config",
            directoryHint: .isDirectory
        )
        for directory in [
            prefix.appending(path: "dosdevices", directoryHint: .isDirectory),
            externalLibrary.appending(
                path: "steamapps",
                directoryHint: .isDirectory
            ),
            steamApps,
            config
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let contentID = "7400000000000000002"
        try writeSteamLibraryFolderIdentity(
            contentID: contentID,
            to: externalLibrary
        )

        let authoritativeURL = steamApps.appending(
            path: "libraryfolders.vdf",
            directoryHint: .notDirectory
        )
        try """
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
        }
        """.write(
            to: authoritativeURL,
            atomically: true,
            encoding: .utf8
        )

        let mapper = SteamLibraryDriveMapper()
        let mappings = try mapper.prepareDriveLinks(
            prefix: prefix,
            libraryRoots: [externalLibrary]
        )
        try mapper.synchronizeDriveMappingsWithSteam(
            prefix: prefix,
            mappings: mappings
        )

        let registrationManifestURL = prefix.appending(
            path: ".forgeplay-library-drives/.steam-library-registrations-v1.json",
            directoryHint: .notDirectory
        )
        let initiallyOwnedManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: registrationManifestURL)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            (initiallyOwnedManifest["ownedRegistrations"] as? [[String: Any]])?
                .count,
            1
        )

        let authoritativeBytes = try Data(contentsOf: authoritativeURL)
        let compatibilityURL = config.appending(
            path: "libraryfolders.vdf",
            directoryHint: .notDirectory
        )
        let compatibilityBytes = Data("""
        // Steam or the user now owns this divergent same-path copy.
        "libraryfolders" {
          "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
          "7" {
            "path" "D:\\\\"
            "contentid" "user-reused-registration"
            "label" "keep this copy"
            "apps" { "990003" "21" }
          }
        }
        """.utf8)
        try compatibilityBytes.write(to: compatibilityURL)

        try mapper.synchronizeDriveMappingsWithSteam(
            prefix: prefix,
            mappings: mappings
        )

        XCTAssertEqual(
            try Data(contentsOf: authoritativeURL),
            authoritativeBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: compatibilityURL),
            compatibilityBytes
        )
        let relinquishedManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: registrationManifestURL)
            ) as? [String: Any]
        )
        XCTAssertEqual(relinquishedManifest["version"] as? Int, 3)
        XCTAssertTrue(
            (relinquishedManifest["ownedRegistrations"] as? [[String: Any]])?
                .isEmpty == true
        )

        // Read back the relinquished state through the normal empty inventory
        // path. Neither divergent Steam copy may become removable afterward.
        try mapper.synchronizeDriveMappingsWithSteam(
            prefix: prefix,
            mappings: []
        )
        XCTAssertEqual(
            try Data(contentsOf: authoritativeURL),
            authoritativeBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: compatibilityURL),
            compatibilityBytes
        )
    }

    func testLibraryRootDiscoveryPreservesVerifiedDirectSelectionForms() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayDirectLibraryDiscovery-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let steamApps = root.appending(
            path: "steamapps",
            directoryHint: .isDirectory
        )
        let common = steamApps.appending(
            path: "common",
            directoryHint: .isDirectory
        )
        let installedGame = common.appending(
            path: "VerifiedGame",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: installedGame,
            withIntermediateDirectories: true
        )

        let steamManager = makeSteamManager(pathManager: PathManager())
        let cases: [
            (
                selected: URL,
                resolution: SteamLibraryRootDiscoveryResolution
            )
        ] = [
            (root, .directLibraryRoot),
            (steamApps, .selectedSteamApps),
            (common, .selectedCommon),
            (installedGame, .selectedInstalledGame)
        ]

        for testCase in cases {
            let discovery = steamManager.libraryRootDiscovery(
                for: testCase.selected
            )
            XCTAssertEqual(discovery.libraryRoots, [root.standardizedFileURL])
            XCTAssertEqual(discovery.resolution, testCase.resolution)
            XCTAssertNil(discovery.failure)
            XCTAssertTrue(discovery.isComplete)
        }
    }

    func testDirectSteamAppsAuthorizationGrantsExactChildWithoutParentMutation()
        throws
    {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayDirectSteamAppsAccess-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(
            fixtureRoot.appending(path: "Managed", directoryHint: .isDirectory)
        )
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let prefixSteamApps = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        let dosdevices = prefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        let libraryRoot = fixtureRoot.appending(
            path: "External/SteamLibrary",
            directoryHint: .isDirectory
        )
        let selectedSteamApps = libraryRoot.appending(
            path: "steamapps",
            directoryHint: .isDirectory
        )
        for directory in [
            prefixSteamApps,
            dosdevices,
            selectedSteamApps.appending(
                path: "common/Helldivers 2",
                directoryHint: .isDirectory
            )
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try writeSteamLibraryFolderIdentity(
            contentID: "7400000000000000206",
            to: libraryRoot
        )

        let manager = makeSteamManager(pathManager: pathManager)
        let parentPreparation = try manager
            .prepareSteamLibraryDriveLinksWithEvidence(
                prefix: prefix,
                libraryRoots: [libraryRoot]
            )
        let parentMapping = try XCTUnwrap(parentPreparation.mappings.first)
        XCTAssertEqual(parentPreparation.mappings.count, 1)
        XCTAssertEqual(parentMapping.macDriveRootURL, libraryRoot)
        XCTAssertEqual(parentMapping.macLibraryURL, libraryRoot)
        XCTAssertEqual(
            parentPreparation.externalStorageRoots,
            [libraryRoot.standardizedFileURL]
        )
        try manager.synchronizeSteamLibraryRegistrations(
            prefix: prefix,
            mappings: parentPreparation.mappings,
            pendingMappings: parentPreparation.pendingMappings,
            discoveries: parentPreparation.discoveries
        )

        let libraryFoldersURL = prefixSteamApps.appending(
            path: "libraryfolders.vdf",
            directoryHint: .notDirectory
        )
        let ownershipManifestURL = prefix.appending(
            path: ".forgeplay-library-drives/.steam-library-registrations-v1.json",
            directoryHint: .notDirectory
        )
        let originalLibraryFolders = try Data(contentsOf: libraryFoldersURL)
        let originalOwnershipManifest = try Data(
            contentsOf: ownershipManifestURL
        )
        let driveAssignmentURL = prefix.appending(
            path: ".forgeplay-library-drives/\(parentMapping.driveLetter.lowercased())/.assignment-v1.json",
            directoryHint: .notDirectory
        )
        let originalDriveAssignment = try Data(contentsOf: driveAssignmentURL)
        let originalDriveTarget = try FileManager.default
            .destinationOfSymbolicLink(
                atPath: dosdevices.appending(
                    path: "\(parentMapping.driveLetter.lowercased()):"
                ).path
            )

        let directPreparation = try manager
            .prepareSteamLibraryDriveLinksWithEvidence(
                prefix: prefix,
                libraryRoots: [selectedSteamApps]
            )
        XCTAssertTrue(directPreparation.mappings.isEmpty)
        XCTAssertTrue(directPreparation.pendingMappings.isEmpty)
        XCTAssertEqual(
            directPreparation.externalStorageRoots,
            [selectedSteamApps.standardizedFileURL]
        )
        XCTAssertEqual(
            directPreparation.discoveries.map(\.resolution),
            [.selectedSteamApps]
        )

        try manager.synchronizeSteamLibraryRegistrations(
            prefix: prefix,
            mappings: directPreparation.mappings,
            pendingMappings: directPreparation.pendingMappings,
            discoveries: directPreparation.discoveries
        )

        XCTAssertEqual(
            try Data(contentsOf: libraryFoldersURL),
            originalLibraryFolders
        )
        XCTAssertEqual(
            try Data(contentsOf: ownershipManifestURL),
            originalOwnershipManifest
        )
        XCTAssertEqual(
            try Data(contentsOf: driveAssignmentURL),
            originalDriveAssignment
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: dosdevices.appending(
                    path: "\(parentMapping.driveLetter.lowercased()):"
                ).path
            ),
            originalDriveTarget
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dosdevices.appending(path: "e:").path
            ),
            "A selected steamapps child must not become a synthetic drive root"
        )
    }

    func testLibraryRootDiscoveryRejectsUnverifiedArbitraryRoot() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayUnverifiedLibraryDiscovery-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: "Documents", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        let steamManager = makeSteamManager(pathManager: PathManager())
        let discovery = steamManager.libraryRootDiscovery(for: root)

        XCTAssertTrue(discovery.libraryRoots.isEmpty)
        XCTAssertNil(discovery.resolution)
        guard let failure = discovery.failure,
              case .noVerifiedSteamLibrary(
                  let failedRoot,
                  let skippedPaths
              ) = failure else {
            return XCTFail("Expected noVerifiedSteamLibrary, got \(String(describing: discovery.failure))")
        }
        XCTAssertEqual(failedRoot, root.standardizedFileURL)
        XCTAssertEqual(
            skippedPaths,
            [root.appending(path: "steamapps", directoryHint: .isDirectory)
                .standardizedFileURL.path]
        )
        XCTAssertTrue(steamManager.normalizedLibraryRoots(for: root).isEmpty)
    }

    func testLibraryRootDiscoveryTraversalFailureProducesTypedFailure() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayLibraryTraversalFailure-\(UUID().uuidString)",
            directoryHint: .notDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)

        let steamManager = makeSteamManager(pathManager: PathManager())
        let discovery = steamManager.libraryRootDiscovery(for: root)

        XCTAssertTrue(discovery.libraryRoots.isEmpty)
        guard let failure = discovery.failure,
              case .traversalFailed(let failedRoot, let reason) = failure else {
            return XCTFail("Expected traversalFailed, got \(String(describing: discovery.failure))")
        }
        XCTAssertEqual(failedRoot, root.standardizedFileURL)
        XCTAssertFalse(reason.isEmpty)
    }

    func testBlankStorageRootIsMappedWithoutLibraryRegistrationAndPersistsAwaitingAudit() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayLibraryDiscoveryAudit-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let managedRoot = temporaryRoot.appending(
            path: "Managed",
            directoryHint: .isDirectory
        )
        let unverifiedRoot = temporaryRoot.appending(
            path: "ExternalVolume",
            directoryHint: .isDirectory
        )
        let auditDirectory = temporaryRoot.appending(
            path: "Audit",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(managedRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: dosdevices,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: unverifiedRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: auditDirectory,
            withIntermediateDirectories: true
        )

        let preparation = try steamManager
            .prepareSteamLibraryDriveLinksWithEvidence(
                prefix: prefix,
                libraryRoots: [unverifiedRoot],
                logDirectory: auditDirectory
        )
        XCTAssertTrue(preparation.mappings.isEmpty)
        XCTAssertTrue(preparation.pendingMappings.isEmpty)
        XCTAssertEqual(
            preparation.externalStorageRoots,
            [unverifiedRoot.standardizedFileURL]
        )
        guard case .noVerifiedSteamLibrary(let failedRoot, _)? =
                preparation.discoveries.first?.failure else {
            return XCTFail("Expected blank-storage discovery state")
        }
        XCTAssertEqual(failedRoot, unverifiedRoot.standardizedFileURL)
        let driveTarget = try FileManager.default.destinationOfSymbolicLink(
            atPath: dosdevices.appending(path: "d:").path
        )
        XCTAssertEqual(
            URL(fileURLWithPath: driveTarget, isDirectory: true)
                .standardizedFileURL.path,
            unverifiedRoot.standardizedFileURL.path
        )
        try steamManager.synchronizeSteamLibraryRegistrations(
            prefix: prefix,
            mappings: preparation.mappings,
            discoveries: preparation.discoveries,
            logDirectory: auditDirectory
        )

        let auditFiles = try FileManager.default.contentsOfDirectory(
            at: auditDirectory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("steam_library_registration_") &&
                $0.pathExtension == "json"
        }
        XCTAssertEqual(auditFiles.count, 1)
        let auditURL = try XCTUnwrap(auditFiles.first)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: auditURL)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            document["status"] as? String,
            "storage_drive_ready_no_existing_library"
        )
        XCTAssertTrue((document["mappings"] as? [[String: Any]])?.isEmpty == true)
        let discoveryRecords = try XCTUnwrap(
            document["library_discovery"] as? [[String: Any]]
        )
        XCTAssertEqual(discoveryRecords.count, 1)
        let discovery = try XCTUnwrap(discoveryRecords.first)
        XCTAssertEqual(
            discovery["selected_root_path"] as? String,
            unverifiedRoot.standardizedFileURL.path
        )
        XCTAssertEqual(
            discovery["failure_type"] as? String,
            "no_verified_steam_library"
        )
        XCTAssertTrue(
            (discovery["verified_library_paths"] as? [String])?.isEmpty == true
        )
    }

    func testDriveSourceContainmentFailureDoesNotMutateDriveLinks() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayDriveSourcePreflight-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let prefix = temporaryRoot.appending(
            path: "Prefix",
            directoryHint: .isDirectory
        )
        let authorizedRoot = temporaryRoot.appending(
            path: "Authorized",
            directoryHint: .isDirectory
        )
        let outsideLibrary = temporaryRoot.appending(
            path: "OutsideLibrary",
            directoryHint: .isDirectory
        )
        let dosdevices = prefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        for directory in [dosdevices, authorizedRoot, outsideLibrary] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        XCTAssertThrowsError(
            try SteamLibraryDriveMapper().prepareDriveLinks(
                prefix: prefix,
                sources: [
                    SteamLibraryDriveSource(
                        authorizedRootURL: authorizedRoot,
                        libraryURL: outsideLibrary
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? SteamLibraryDriveBridgeError,
                .libraryRootUnavailable(outsideLibrary)
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prefix.appending(
                    path: ".forgeplay-library-drives",
                    directoryHint: .isDirectory
                ).path
            )
        )
        XCTAssertNil(
            try? FileManager.default.destinationOfSymbolicLink(
                atPath: dosdevices.appending(path: "d:").path
            )
        )
    }

    func testDriveAllocatorSkipsDeviceOnlyAndOccupiedLettersWhenRegisteringComputedPath() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayGeneralDriveAllocation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let prefix = temporaryRoot.appending(
            path: "Prefix",
            directoryHint: .isDirectory
        )
        let driveRoot = temporaryRoot.appending(
            path: "Selected Storage \(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let library = driveRoot.appending(
            path: "Library With Spaces",
            directoryHint: .isDirectory
        )
        let unrelatedTarget = temporaryRoot.appending(
            path: "Unrelated",
            directoryHint: .isDirectory
        )
        let dosdevices = prefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        let steamApps = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        let deviceOnlyLink = dosdevices.appending(path: "d::")
        let occupiedDriveLink = dosdevices.appending(path: "e:")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        for directory in [
            dosdevices,
            steamApps,
            library.appending(path: "steamapps", directoryHint: .isDirectory),
            unrelatedTarget
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try writeSteamLibraryFolderIdentity(
            contentID: "1032535092539837421",
            to: library
        )
        let unavailableDevicePath =
            "/dev/forgeplay-test-\(UUID().uuidString.lowercased())"
        try FileManager.default.createSymbolicLink(
            atPath: deviceOnlyLink.path,
            withDestinationPath: unavailableDevicePath
        )
        try FileManager.default.createSymbolicLink(
            at: occupiedDriveLink,
            withDestinationURL: unrelatedTarget
        )

        let mapper = SteamLibraryDriveMapper()
        let mappings = try mapper.prepareDriveLinks(
            prefix: prefix,
            sources: [
                SteamLibraryDriveSource(
                    authorizedRootURL: driveRoot,
                    libraryURL: library
                )
            ]
        )
        let mapping = try XCTUnwrap(mappings.first)
        XCTAssertEqual(mapping.driveLetter, "f")
        XCTAssertEqual(mapping.windowsLibraryPath, "F:\\Library With Spaces")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: deviceOnlyLink.path
            ),
            unavailableDevicePath
        )
        XCTAssertNil(
            try? FileManager.default.destinationOfSymbolicLink(
                atPath: dosdevices.appending(path: "d:").path
            )
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: occupiedDriveLink.path
            ),
            unrelatedTarget.path
        )

        try mapper.synchronizeDriveMappingsWithSteam(
            prefix: prefix,
            mappings: mappings
        )
        let libraryFoldersText = try XCTUnwrap(
            SteamVDFFileReader.readText(
                steamApps.appending(path: "libraryfolders.vdf"),
                maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes
            )
        )
        let libraryFolders = try XCTUnwrap(
            VDFParser().parse(libraryFoldersText)["libraryfolders"]?.objectValue
        )
        XCTAssertTrue(
            libraryFolders.values.contains {
                $0.objectValue?["path"]?.stringValue ==
                    "F:\\Library With Spaces"
            }
        )
    }

    func testDriveAllocatorDoesNotAdoptMatchingPathWithUnverifiedDevicePair() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayUnverifiedDevicePair-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let prefix = temporaryRoot.appending(
            path: "Prefix",
            directoryHint: .isDirectory
        )
        let library = temporaryRoot.appending(
            path: "SteamLibrary",
            directoryHint: .isDirectory
        )
        let dosdevices = prefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        let driveLink = dosdevices.appending(path: "d:")
        let deviceLink = dosdevices.appending(path: "d::")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        for directory in [dosdevices, library] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try writeSteamLibraryFolderIdentity(
            contentID: "4101409350021775011",
            to: library
        )
        try FileManager.default.createSymbolicLink(
            at: driveLink,
            withDestinationURL: library
        )
        let deviceTarget =
            "/dev/forgeplay-test-\(UUID().uuidString.lowercased())"
        try FileManager.default.createSymbolicLink(
            atPath: deviceLink.path,
            withDestinationPath: deviceTarget
        )

        let mappings = try SteamLibraryDriveMapper().prepareDriveLinks(
            prefix: prefix,
            libraryRoots: [library]
        )

        XCTAssertEqual(mappings.first?.driveLetter, "e")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: driveLink.path
            ),
            library.path
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: deviceLink.path
            ),
            deviceTarget
        )
    }

    func testRegistrationUsesExistingCanonicalAliasWithoutClaimingOrDuplicatingIt() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayCanonicalLibraryAlias-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let prefix = temporaryRoot.appending(
            path: "Prefix",
            directoryHint: .isDirectory
        )
        let driveRoot = temporaryRoot.appending(
            path: "SelectedStorage",
            directoryHint: .isDirectory
        )
        let library = driveRoot.appending(
            path: "SteamLibrary",
            directoryHint: .isDirectory
        )
        let dosdevices = prefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        let steamApps = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        let existingAliasLink = dosdevices.appending(path: "g:")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        for directory in [
            dosdevices,
            steamApps,
            library.appending(path: "steamapps", directoryHint: .isDirectory)
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try writeSteamLibraryFolderIdentity(
            contentID: "5720700158910897367",
            to: library
        )
        try FileManager.default.createSymbolicLink(
            at: existingAliasLink,
            withDestinationURL: driveRoot
        )
        let libraryFoldersURL = steamApps.appending(
            path: "libraryfolders.vdf"
        )
        try """
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
            "1" {
                "path" "G:\\\\SteamLibrary"
                "contentid" "user-owned-alias"
                "apps" { }
            }
        }
        """.write(
            to: libraryFoldersURL,
            atomically: true,
            encoding: .utf8
        )
        let steamOwnedLibraryFoldersData = try Data(
            contentsOf: libraryFoldersURL
        )

        let mapper = SteamLibraryDriveMapper()
        let mappings = try mapper.prepareDriveLinks(
            prefix: prefix,
            sources: [
                SteamLibraryDriveSource(
                    authorizedRootURL: driveRoot,
                    libraryURL: library
                )
            ]
        )
        XCTAssertEqual(mappings.first?.windowsLibraryPath, "D:\\SteamLibrary")

        try mapper.synchronizeDriveMappingsWithSteam(
            prefix: prefix,
            mappings: mappings
        )

        XCTAssertEqual(
            try Data(contentsOf: libraryFoldersURL),
            steamOwnedLibraryFoldersData,
            "An equivalent Steam-owned canonical alias must be a byte-stable no-op."
        )
        let firstDocument = try XCTUnwrap(
            VDFParser().parse(
                try XCTUnwrap(
                    SteamVDFFileReader.readText(
                        libraryFoldersURL,
                        maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes
                    )
                )
            )["libraryfolders"]?.objectValue
        )
        let firstPaths = Set(firstDocument.values.compactMap {
            $0.objectValue?["path"]?.stringValue
        })
        XCTAssertTrue(firstPaths.contains("G:\\SteamLibrary"))
        XCTAssertFalse(firstPaths.contains("D:\\SteamLibrary"))
        let manifestURL = prefix.appending(
            path: ".forgeplay-library-drives/.steam-library-registrations-v1.json"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: manifestURL.path),
            "A Steam-owned canonical alias must not create ForgePlay ownership state."
        )

        try FileManager.default.removeItem(at: existingAliasLink)
        try FileManager.default.createSymbolicLink(
            atPath: existingAliasLink.path,
            withDestinationPath:
                temporaryRoot.appending(path: "MissingStorage").path
        )
        try mapper.synchronizeDriveMappingsWithSteam(
            prefix: prefix,
            mappings: mappings
        )

        let secondDocument = try XCTUnwrap(
            VDFParser().parse(
                try XCTUnwrap(
                    SteamVDFFileReader.readText(
                        libraryFoldersURL,
                        maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes
                    )
                )
            )["libraryfolders"]?.objectValue
        )
        let secondPaths = Set(secondDocument.values.compactMap {
            $0.objectValue?["path"]?.stringValue
        })
        XCTAssertTrue(secondPaths.contains("G:\\SteamLibrary"))
        XCTAssertTrue(secondPaths.contains("D:\\SteamLibrary"))
    }

    func testPrepareSteamLibraryDriveLinksMapsSelectedVolumeDirectlyAndRegistersNestedLibraryPath() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySelectedVolumeMapping-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let managedRoot = temporaryRoot.appending(path: "Managed", directoryHint: .isDirectory)
        let selectedVolume = temporaryRoot.appending(
            path: "ExternalVolume",
            directoryHint: .isDirectory
        )
        let library = selectedVolume.appending(
            path: "SteamLibrary",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(managedRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: library.appending(path: "steamapps", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try writeSteamLibraryFolderIdentity(
            contentID: "5188427214108100536",
            to: library
        )

        let mappings = try steamManager.prepareSteamLibraryDriveLinks(
            prefix: prefix,
            libraryRoots: [selectedVolume]
        )

        XCTAssertEqual(mappings.count, 1)
        XCTAssertEqual(mappings.first?.macDriveRootURL, selectedVolume.standardizedFileURL)
        XCTAssertEqual(mappings.first?.macLibraryURL, library.standardizedFileURL)
        XCTAssertEqual(mappings.first?.windowsLibraryPath, "D:\\SteamLibrary")
        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: dosdevices.appending(path: "d:").path
        )
        XCTAssertEqual(
            URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL.path,
            selectedVolume.standardizedFileURL.path
        )
        XCTAssertEqual(
            SteamManager.mappedWindowsLibraryPath(for: library, prefix: prefix),
            "D:\\SteamLibrary"
        )
    }

    func testPrepareSteamLibraryDriveLinksCreatesWineDosdeviceSymlink() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamDriveRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLibrary = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalSteamLibrary-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            try? FileManager.default.removeItem(at: externalLibrary)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamApps = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: externalLibrary.appending(path: "steamapps", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try writeSteamLibraryFolderIdentity(
            contentID: "7741412482759017262",
            to: externalLibrary
        )
        try writeManifest(
            appId: "220",
            name: "Half-Life 2",
            installDir: "Half-Life 2",
            to: externalLibrary.appending(path: "steamapps/appmanifest_220.acf")
        )
        try FileManager.default.createSymbolicLink(
            at: dosdevices.appending(path: "d:"),
            withDestinationURL: externalLibrary
        )
        let libraryFoldersContents = """
        "libraryfolders"
        {
            "0"
            {
                "path" "C:\\\\Program Files (x86)\\\\Steam"
                "apps" { }
            }
            "1"
            {
                "path" "D:"
                "apps"
                {
                    "220" "8"
                }
            }
            "2"
            {
                "path" "G:\\\\UserManagedLibrary"
                "apps" { }
            }
        }
        """
        try libraryFoldersContents.write(
            to: steamApps.appending(path: "libraryfolders.vdf"),
            atomically: true,
            encoding: .utf8
        )

        let mappings = try steamManager.prepareSteamLibraryDriveLinks(
            prefix: prefix,
            libraryRoots: [externalLibrary]
        )

        XCTAssertEqual(mappings, [
            SteamLibraryDriveMapping(
                driveLetter: "d",
                macLibraryURL: externalLibrary.standardizedFileURL,
                windowsLibraryPath: "D:\\"
            )
        ])
        let link = dosdevices.appending(path: "d:")
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        let bridgeRoot = prefix.appending(
            path: ".forgeplay-library-drives/d",
            directoryHint: .isDirectory
        )
        XCTAssertEqual(
            URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL.path,
            externalLibrary.standardizedFileURL.path
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: bridgeRoot.appending(path: "SteamLibrary").path
            ),
            externalLibrary.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(
            SteamLibraryDriveMapper.macURL(
                fromSteamLibraryPath: "D:\\steamapps",
                prefix: prefix
            ).path,
            externalLibrary.appending(path: "steamapps", directoryHint: .isDirectory).path
        )

        _ = try steamManager.prepareSteamLibraryDriveLinks(
            prefix: prefix,
            libraryRoots: [externalLibrary]
        )
        let libraryFoldersURL = steamApps.appending(path: "libraryfolders.vdf")
        XCTAssertEqual(
            try Data(contentsOf: libraryFoldersURL),
            Data(libraryFoldersContents.utf8),
            "Drive preparation alone must not rewrite Steam storage registrations."
        )
        XCTAssertEqual(
            SteamManager.mappedWindowsLibraryPath(for: externalLibrary, prefix: prefix),
            "D:\\"
        )
    }

    func testPrepareSteamLibraryDriveLinksPreservesPreexistingMatchingWineSymlink() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayPreexistingWineDrive-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let prefix = temporaryRoot.appending(
            path: "Prefix",
            directoryHint: .isDirectory
        )
        let externalLibrary = temporaryRoot.appending(
            path: "External/SteamLibrary",
            directoryHint: .isDirectory
        )
        let dosdevices = prefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        let driveLink = dosdevices.appending(path: "d:")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try FileManager.default.createDirectory(
            at: dosdevices,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalLibrary,
            withIntermediateDirectories: true
        )
        try writeSteamLibraryFolderIdentity(
            contentID: "4968329345408527691",
            to: externalLibrary
        )
        try FileManager.default.createSymbolicLink(
            at: driveLink,
            withDestinationURL: externalLibrary
        )

        let mapper = SteamLibraryDriveMapper()
        let mappings = try mapper.prepareDriveLinks(
            prefix: prefix,
            libraryRoots: [externalLibrary]
        )

        XCTAssertEqual(mappings.first?.driveLetter, "d")
        let assignmentURL = prefix.appending(
            path: ".forgeplay-library-drives/d/.assignment-v1.json"
        )
        let assignment = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: assignmentURL)
            ) as? [String: Any]
        )
        XCTAssertEqual(assignment["version"] as? Int, 3)
        XCTAssertEqual(
            assignment["driveLinkOwnership"] as? String,
            "external"
        )
        XCTAssertEqual(assignment["isReservedOnly"] as? Bool, false)

        _ = try mapper.prepareDriveLinks(prefix: prefix, libraryRoots: [])

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: driveLink.path
            ),
            externalLibrary.path
        )
    }

    func testSteamLibraryRegistrationUsesOwnedDirectDriveAndPreservesUserEntries() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamRegistration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let externalLibrary = temporaryRoot.appending(
            path: "External/SteamLibrary",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(
            temporaryRoot.appending(path: "Managed", directoryHint: .isDirectory)
        )
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let steamDirectory = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        let steamApps = steamDirectory.appending(
            path: "steamapps",
            directoryHint: .isDirectory
        )
        let config = steamDirectory.appending(
            path: "config",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: prefix.appending(path: "dosdevices", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalLibrary.appending(path: "steamapps", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let externalLibraryContentID = "4085398257920183726"
        try writeSteamLibraryFolderIdentity(
            contentID: externalLibraryContentID,
            to: externalLibrary
        )
        try FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let authoritative = """
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
            "1" { "path" "G:\\\\UserManagedLibrary" "apps" { "111" "1" } }
        }
        """
        let compatibility = """
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
            "1" { "path" "G:\\\\UserManagedLibrary" "apps" { "222" "1" } }
        }
        """
        try authoritative.write(
            to: steamApps.appending(path: "libraryfolders.vdf"),
            atomically: true,
            encoding: .utf8
        )
        try compatibility.write(
            to: config.appending(path: "libraryfolders.vdf"),
            atomically: true,
            encoding: .utf8
        )

        let mappings = try steamManager.prepareSteamLibraryDriveLinks(
            prefix: prefix,
            libraryRoots: [externalLibrary]
        )
        try steamManager.synchronizeSteamLibraryRegistrations(
            prefix: prefix,
            mappings: mappings
        )

        for url in [
            steamApps.appending(path: "libraryfolders.vdf"),
            config.appending(path: "libraryfolders.vdf")
        ] {
            let text = try XCTUnwrap(
                try SteamVDFFileReader.readText(
                    url,
                    maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes
                )
            )
            let folders = try XCTUnwrap(
                VDFParser().parse(text)["libraryfolders"]?.objectValue
            )
            XCTAssertEqual(
                Set(folders.values.compactMap {
                    $0.objectValue?["path"]?.stringValue
                }),
                Set([
                    "C:\\Program Files (x86)\\Steam",
                    "G:\\UserManagedLibrary",
                    "D:\\"
                ])
            )
            let userEntry = try XCTUnwrap(folders.values.first {
                $0.objectValue?["path"]?.stringValue == "G:\\UserManagedLibrary"
            })
            XCTAssertEqual(
                Set(try XCTUnwrap(userEntry.objectValue?["apps"]?.objectValue).keys),
                Set(["111", "222"])
            )
            let externalEntry = try XCTUnwrap(folders.values.first {
                $0.objectValue?["path"]?.stringValue == "D:\\"
            })
            XCTAssertEqual(
                externalEntry.objectValue?["contentid"]?.stringValue,
                externalLibraryContentID,
                "Steam must receive the contentid from the library root's own libraryfolder.vdf."
            )
        }

        let registrationManifest = prefix.appending(
            path: ".forgeplay-library-drives/.steam-library-registrations-v1.json"
        )
        let manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: registrationManifest)
            ) as? [String: Any]
        )
        XCTAssertEqual(manifestObject["version"] as? Int, 3)
        let ownedRegistrations = try XCTUnwrap(
            manifestObject["ownedRegistrations"] as? [[String: Any]]
        )
        XCTAssertEqual(
            ownedRegistrations.compactMap {
                $0["normalizedWindowsPath"] as? String
            },
            ["d:\\"]
        )
        XCTAssertEqual(
            ownedRegistrations.first?["canonicalLibraryPath"] as? String,
            externalLibrary.resolvingSymlinksInPath().standardizedFileURL.path
        )
        XCTAssertEqual(
            ownedRegistrations.first?["contentID"] as? String,
            externalLibraryContentID
        )

        _ = try steamManager.prepareSteamLibraryDriveLinks(
            prefix: prefix,
            libraryRoots: []
        )
        try steamManager.synchronizeSteamLibraryRegistrations(
            prefix: prefix,
            mappings: []
        )
        let finalText = try XCTUnwrap(
            try SteamVDFFileReader.readText(
                steamApps.appending(path: "libraryfolders.vdf"),
                maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes
            )
        )
        let finalFolders = try XCTUnwrap(
            VDFParser().parse(finalText)["libraryfolders"]?.objectValue
        )
        XCTAssertEqual(
            Set(finalFolders.values.compactMap {
                $0.objectValue?["path"]?.stringValue
            }),
            Set([
                "C:\\Program Files (x86)\\Steam",
                "G:\\UserManagedLibrary"
            ])
        )
    }

    func testSteamLibraryRegistrationMigratesLegacyForgePlayContentIDAfterStableVolumeRemount() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamRegistrationIdentityMigration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let prefix = temporaryRoot.appending(path: "Prefix", directoryHint: .isDirectory)
        let externalLibrary = temporaryRoot.appending(
            path: "External/SteamLibrary",
            directoryHint: .isDirectory
        )
        let steamApps = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        let bridgeDirectory = prefix.appending(
            path: ".forgeplay-library-drives",
            directoryHint: .isDirectory
        )
        for directory in [
            prefix.appending(path: "dosdevices", directoryHint: .isDirectory),
            externalLibrary.appending(path: "steamapps", directoryHint: .isDirectory),
            steamApps,
            bridgeDirectory
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let steamContentID = "4085398257920183726"
        try writeSteamLibraryFolderIdentity(
            contentID: steamContentID,
            to: externalLibrary
        )
        let canonicalLibraryPath = externalLibrary.resolvingSymlinksInPath()
            .standardizedFileURL.path
        let previousCanonicalLibraryPath = temporaryRoot.appending(
            path: "PreviousMount/SteamLibrary",
            directoryHint: .isDirectory
        ).standardizedFileURL.path
        let legacyContentID = legacyForgePlayStableContentID(
            for: previousCanonicalLibraryPath
        )
        try """
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
            "1" {
                "path" "D:"
                "contentid" "\(legacyContentID)"
                "totalsize" "3600000000000"
                "apps" { "777" "1" }
            }
        }
        """.write(
            to: steamApps.appending(path: "libraryfolders.vdf"),
            atomically: true,
            encoding: .utf8
        )
        let legacyManifest: [String: Any] = [
            "version": 2,
            "ownedRegistrations": [[
                "normalizedWindowsPath": "d:\\",
                "driveRootStorageIdentity": "fixture-storage",
                "canonicalDriveRootPath": previousCanonicalLibraryPath,
                "canonicalLibraryPath": previousCanonicalLibraryPath,
                "contentID": legacyContentID
            ]]
        ]
        try JSONSerialization.data(
            withJSONObject: legacyManifest,
            options: [.sortedKeys]
        ).write(
            to: bridgeDirectory.appending(
                path: ".steam-library-registrations-v1.json"
            )
        )

        let mapper = SteamLibraryDriveMapper(
            storageIdentityProvider: { _ in "fixture-storage" }
        )
        let mappings = try mapper.prepareDriveLinks(
            prefix: prefix,
            libraryRoots: [externalLibrary]
        )
        try mapper.synchronizeDriveMappingsWithSteam(
            prefix: prefix,
            mappings: mappings
        )

        let text = try XCTUnwrap(
            SteamVDFFileReader.readText(
                steamApps.appending(path: "libraryfolders.vdf"),
                maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes
            )
        )
        let folders = try XCTUnwrap(
            VDFParser().parse(text)["libraryfolders"]?.objectValue
        )
        let externalEntry = try XCTUnwrap(folders.values.first {
            $0.objectValue?["path"]?.stringValue == "D:"
        })
        XCTAssertEqual(
            externalEntry.objectValue?["contentid"]?.stringValue,
            steamContentID
        )
        XCTAssertNotEqual(steamContentID, legacyContentID)
        XCTAssertEqual(
            externalEntry.objectValue?["totalsize"]?.stringValue,
            "3600000000000"
        )
        XCTAssertEqual(
            externalEntry.objectValue?["apps"]?.objectValue?["777"]?
                .stringValue,
            "1"
        )
        let migratedManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: bridgeDirectory.appending(
                    path: ".steam-library-registrations-v1.json"
                ))
            ) as? [String: Any]
        )
        XCTAssertEqual(migratedManifest["version"] as? Int, 3)
        XCTAssertEqual(
            (migratedManifest["ownedRegistrations"] as? [[String: Any]])?
                .first?["contentID"] as? String,
            steamContentID
        )
        XCTAssertEqual(
            (migratedManifest["ownedRegistrations"] as? [[String: Any]])?
                .first?["canonicalDriveRootPath"] as? String,
            canonicalLibraryPath
        )
        XCTAssertEqual(
            (migratedManifest["ownedRegistrations"] as? [[String: Any]])?
                .first?["canonicalLibraryPath"] as? String,
            canonicalLibraryPath
        )
    }

    func testSteamLibraryRegistrationWithoutSteamIdentityFailsBeforeDriveOrVDFMutation() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamRegistrationMissingIdentity-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let prefix = temporaryRoot.appending(path: "Prefix", directoryHint: .isDirectory)
        let externalLibrary = temporaryRoot.appending(
            path: "External/SteamLibrary",
            directoryHint: .isDirectory
        )
        let steamApps = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: prefix.appending(path: "dosdevices", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalLibrary.appending(path: "steamapps", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: steamApps,
            withIntermediateDirectories: true
        )
        let libraryFoldersURL = steamApps.appending(path: "libraryfolders.vdf")
        let original = Data("""
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
        }
        """.utf8)
        try original.write(to: libraryFoldersURL)
        let mapper = SteamLibraryDriveMapper()
        XCTAssertThrowsError(
            try mapper.prepareDriveLinks(
                prefix: prefix,
                libraryRoots: [externalLibrary]
            )
        )
        XCTAssertEqual(try Data(contentsOf: libraryFoldersURL), original)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prefix.appending(path: "dosdevices/d:").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prefix.appending(
                    path: ".forgeplay-library-drives"
                ).path
            )
        )
    }

    func testSteamLibraryRegistrationDoesNotClaimPreexistingMatchingPath() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamRegistrationOwnership-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let externalLibrary = temporaryRoot.appending(
            path: "External/SteamLibrary",
            directoryHint: .isDirectory
        )
        let contentID = "424242"
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(
            temporaryRoot.appending(path: "Managed", directoryHint: .isDirectory)
        )
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let steamApps = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: prefix.appending(path: "dosdevices", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalLibrary.appending(path: "steamapps", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try writeSteamLibraryFolderIdentity(
            contentID: contentID,
            to: externalLibrary
        )
        try FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)
        try """
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
            "1" { "path" "D:\\\\" "contentid" "\(contentID)" "apps" { } }
        }
        """.write(
            to: steamApps.appending(path: "libraryfolders.vdf"),
            atomically: true,
            encoding: .utf8
        )

        let mappings = try steamManager.prepareSteamLibraryDriveLinks(
            prefix: prefix,
            libraryRoots: [externalLibrary]
        )
        try steamManager.synchronizeSteamLibraryRegistrations(
            prefix: prefix,
            mappings: mappings
        )
        _ = try steamManager.prepareSteamLibraryDriveLinks(
            prefix: prefix,
            libraryRoots: []
        )
        try steamManager.synchronizeSteamLibraryRegistrations(
            prefix: prefix,
            mappings: []
        )

        let text = try XCTUnwrap(
            try SteamVDFFileReader.readText(
                steamApps.appending(path: "libraryfolders.vdf"),
                maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes
            )
        )
        let folders = try XCTUnwrap(
            VDFParser().parse(text)["libraryfolders"]?.objectValue
        )
        XCTAssertTrue(folders.values.contains {
            $0.objectValue?["path"]?.stringValue == "D:\\"
        })
    }

    func testSteamLibraryRegistrationPreservesUserReusedOwnedPath() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySteamRegistrationReuse-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let prefix = temporaryRoot.appending(
            path: "Prefix",
            directoryHint: .isDirectory
        )
        let externalLibrary = temporaryRoot.appending(
            path: "External/SteamLibrary",
            directoryHint: .isDirectory
        )
        let steamApps = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        let libraryFoldersURL = steamApps.appending(
            path: "libraryfolders.vdf"
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try FileManager.default.createDirectory(
            at: prefix.appending(path: "dosdevices", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalLibrary,
            withIntermediateDirectories: true
        )
        try writeSteamLibraryFolderIdentity(
            contentID: "6507425299468498951",
            to: externalLibrary
        )
        try FileManager.default.createDirectory(
            at: steamApps,
            withIntermediateDirectories: true
        )
        try """
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
        }
        """.write(
            to: libraryFoldersURL,
            atomically: true,
            encoding: .utf8
        )

        let mapper = SteamLibraryDriveMapper()
        let mappings = try mapper.prepareDriveLinks(
            prefix: prefix,
            libraryRoots: [externalLibrary]
        )
        try mapper.synchronizeDriveMappingsWithSteam(
            prefix: prefix,
            mappings: mappings
        )

        try """
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
            "1"
            {
                "path" "D:\\\\"
                "contentid" "user-reused-registration"
                "apps" { "777" "1" }
            }
        }
        """.write(
            to: libraryFoldersURL,
            atomically: true,
            encoding: .utf8
        )
        _ = try mapper.prepareDriveLinks(prefix: prefix, libraryRoots: [])
        try mapper.synchronizeDriveMappingsWithSteam(
            prefix: prefix,
            mappings: []
        )

        let text = try XCTUnwrap(
            try SteamVDFFileReader.readText(
                libraryFoldersURL,
                maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes
            )
        )
        let folders = try XCTUnwrap(
            VDFParser().parse(text)["libraryfolders"]?.objectValue
        )
        let reusedEntry = try XCTUnwrap(folders.values.first {
            $0.objectValue?["path"]?.stringValue == "D:\\"
        })
        XCTAssertEqual(
            reusedEntry.objectValue?["contentid"]?.stringValue,
            "user-reused-registration"
        )
        XCTAssertEqual(
            Set(
                try XCTUnwrap(
                    reusedEntry.objectValue?["apps"]?.objectValue
                ).keys
            ),
            Set(["777"])
        )
    }

    func testSteamLibraryRegistrationTreatsLegacyPathOnlyManifestAsUnowned() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayLegacyRegistrationManifest-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let prefix = temporaryRoot.appending(
            path: "Prefix",
            directoryHint: .isDirectory
        )
        let steamApps = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        let bridgeDirectory = prefix.appending(
            path: ".forgeplay-library-drives",
            directoryHint: .isDirectory
        )
        let libraryFoldersURL = steamApps.appending(
            path: "libraryfolders.vdf"
        )
        let manifestURL = bridgeDirectory.appending(
            path: ".steam-library-registrations-v1.json"
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try FileManager.default.createDirectory(
            at: steamApps,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bridgeDirectory,
            withIntermediateDirectories: true
        )
        let libraryFolders = """
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
            "1" { "path" "D:\\\\" "contentid" "legacy-user-entry" "apps" { } }
        }
        """
        try libraryFolders.write(
            to: libraryFoldersURL,
            atomically: true,
            encoding: .utf8
        )
        try """
        {"ownedWindowsPaths":["d:\\\\"],"version":1}
        """.write(
            to: manifestURL,
            atomically: true,
            encoding: .utf8
        )

        try SteamLibraryDriveMapper().synchronizeDriveMappingsWithSteam(
            prefix: prefix,
            mappings: []
        )

        XCTAssertEqual(
            try String(contentsOf: libraryFoldersURL, encoding: .utf8),
            libraryFolders
        )
    }

    func testPrepareSteamLibraryDriveLinksDoesNotOverwriteExistingDriveSymlink() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamDriveRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        let existingDriveTarget = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExistingDrive-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLibrary = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalSteamLibrary-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            try? FileManager.default.removeItem(at: existingDriveTarget)
            try? FileManager.default.removeItem(at: externalLibrary)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamApps = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: existingDriveTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: externalLibrary.appending(path: "steamapps", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try writeSteamLibraryFolderIdentity(
            contentID: "6412154253743049014",
            to: externalLibrary
        )
        try FileManager.default.createSymbolicLink(
            at: dosdevices.appending(path: "d:"),
            withDestinationURL: existingDriveTarget
        )

        let mappings = try steamManager.prepareSteamLibraryDriveLinks(
            prefix: prefix,
            libraryRoots: [externalLibrary]
        )

        XCTAssertEqual(mappings.first?.driveLetter, "e")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: dosdevices.appending(path: "d:").path),
            existingDriveTarget.path
        )
        let eTarget = try FileManager.default.destinationOfSymbolicLink(
            atPath: dosdevices.appending(path: "e:").path
        )
        let eBridgeRoot = prefix.appending(
            path: ".forgeplay-library-drives/e",
            directoryHint: .isDirectory
        )
        XCTAssertEqual(
            URL(fileURLWithPath: eTarget, isDirectory: true).standardizedFileURL.path,
            externalLibrary.standardizedFileURL.path
        )
        let eLibraryTarget = try FileManager.default.destinationOfSymbolicLink(
            atPath: eBridgeRoot.appending(path: "SteamLibrary").path
        )
        XCTAssertEqual(eLibraryTarget, externalLibrary.standardizedFileURL.path)
    }

    func testPrepareSteamLibraryDriveLinksMigratesManagedBridgeToDirectDriveLink() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamBridgeMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalDrive = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalDrive-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            try? FileManager.default.removeItem(at: externalDrive)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let legacyBridge = prefix.appending(
            path: ".forgeplay-library-drives/d",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyBridge, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: externalDrive.appending(path: "steamapps", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try writeSteamLibraryFolderIdentity(
            contentID: "2357754945286430920",
            to: externalDrive
        )
        try FileManager.default.createSymbolicLink(
            at: legacyBridge.appending(path: "SteamLibrary"),
            withDestinationURL: externalDrive
        )
        try FileManager.default.createSymbolicLink(
            at: dosdevices.appending(path: "d:"),
            withDestinationURL: legacyBridge
        )

        let mappings = try steamManager.prepareSteamLibraryDriveLinks(
            prefix: prefix,
            libraryRoots: [externalDrive]
        )

        XCTAssertEqual(mappings.first?.windowsLibraryPath, "D:\\")
        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: dosdevices.appending(path: "d:").path
        )
        XCTAssertEqual(
            URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL.path,
            externalDrive.standardizedFileURL.path
        )
    }

    func testPrepareSteamLibraryDriveLinksMapsExactSelectionAndRemovesItWhenDisconnected() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamDirectDrive-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalDrive = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalDrive-\(UUID().uuidString)", directoryHint: .isDirectory)
        let selectedFolder = externalDrive.appending(path: "steamapps", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            try? FileManager.default.removeItem(at: externalDrive)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: selectedFolder, withIntermediateDirectories: true)
        try writeSteamLibraryFolderIdentity(
            contentID: "6671908130541992145",
            to: externalDrive
        )

        let mappings = try steamManager.prepareSteamLibraryDriveLinks(
            prefix: prefix,
            libraryRoots: [externalDrive]
        )

        XCTAssertEqual(mappings.first?.windowsLibraryPath, "D:\\")
        let driveLink = dosdevices.appending(path: "d:")
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: driveLink.path)
        let bridgeRoot = prefix.appending(
            path: ".forgeplay-library-drives/d",
            directoryHint: .isDirectory
        )
        XCTAssertEqual(
            URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL.path,
            externalDrive.standardizedFileURL.path
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: bridgeRoot.appending(path: "SteamLibrary").path
            ),
            externalDrive.standardizedFileURL.path
        )

        _ = try steamManager.prepareSteamLibraryDriveLinks(prefix: prefix, libraryRoots: [])

        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: driveLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: selectedFolder.path))
    }

    func testPrepareSteamLibraryDriveLinksPersistsRestartStableVolumeUUIDIdentity() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamDriveIdentity-\(UUID().uuidString)", directoryHint: .isDirectory)
        let managedRoot = temporaryRoot.appending(path: "Managed", directoryHint: .isDirectory)
        let selectedFolder = temporaryRoot.appending(path: "SteamLibrary", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(managedRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        try FileManager.default.createDirectory(
            at: prefix.appending(path: "dosdevices", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: selectedFolder.appending(path: "steamapps", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try writeSteamLibraryFolderIdentity(
            contentID: "8374593056109446027",
            to: selectedFolder
        )

        let volumeValues = try selectedFolder.resourceValues(forKeys: [.volumeUUIDStringKey])
        guard let volumeUUID = volumeValues.volumeUUIDString, !volumeUUID.isEmpty else {
            throw XCTSkip("The test volume does not expose a persistent volume UUID.")
        }

        let mappings = try steamManager.prepareSteamLibraryDriveLinks(
            prefix: prefix,
            libraryRoots: [selectedFolder]
        )
        let driveLetter = try XCTUnwrap(mappings.first?.driveLetter)
        let assignmentURL = prefix
            .appending(path: ".forgeplay-library-drives/\(driveLetter)", directoryHint: .isDirectory)
            .appending(path: ".assignment-v1.json")
        let assignmentData = try Data(contentsOf: assignmentURL)
        let assignment = try XCTUnwrap(
            JSONSerialization.jsonObject(with: assignmentData) as? [String: Any]
        )
        let storageIdentity = try XCTUnwrap(assignment["storageIdentity"] as? String)

        XCTAssertTrue(
            storageIdentity.hasPrefix("volume-uuid:\(volumeUUID.lowercased()):"),
            "Expected a restart-stable volume UUID identity, got \(storageIdentity)"
        )
    }

    func testPrepareSteamLibraryDriveLinksPreservesLettersAcrossUnavailableReverseReconnect() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamDriveReservation-\(UUID().uuidString)", directoryHint: .isDirectory)
        let libraryA = temporaryRoot.appending(path: "External-A", directoryHint: .isDirectory)
        let libraryB = temporaryRoot.appending(path: "External-B", directoryHint: .isDirectory)
        let libraryC = temporaryRoot.appending(path: "External-C", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot.appending(path: "Managed", directoryHint: .isDirectory))
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        for (index, library) in [libraryA, libraryB, libraryC].enumerated() {
            try FileManager.default.createDirectory(
                at: library.appending(path: "steamapps", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
            try writeSteamLibraryFolderIdentity(
                contentID: String(7_100_000_000_000_000_000 + index),
                to: library
            )
        }

        let initial = try steamManager.prepareSteamLibraryDriveLinks(
            prefix: prefix,
            libraryRoots: [libraryA, libraryB],
            reservedLibraryRoots: [libraryA, libraryB]
        )
        let initialLetters = Dictionary(uniqueKeysWithValues: initial.map {
            ($0.macLibraryURL.standardizedFileURL.path, $0.driveLetter)
        })
        let letterA = try XCTUnwrap(initialLetters[libraryA.standardizedFileURL.path])
        let letterB = try XCTUnwrap(initialLetters[libraryB.standardizedFileURL.path])
        XCTAssertNotEqual(letterA, letterB)

        _ = try steamManager.prepareSteamLibraryDriveLinks(
            prefix: prefix,
            libraryRoots: [],
            reservedLibraryRoots: [libraryA, libraryB]
        )
        XCTAssertThrowsError(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: dosdevices.appending(path: "\(letterA):").path
            )
        )

        let reverseReconnect = try steamManager.prepareSteamLibraryDriveLinks(
            prefix: prefix,
            libraryRoots: [libraryB],
            reservedLibraryRoots: [libraryA, libraryB]
        )
        XCTAssertEqual(reverseReconnect.first?.driveLetter, letterB)

        let allReconnected = try steamManager.prepareSteamLibraryDriveLinks(
            prefix: prefix,
            libraryRoots: [libraryB, libraryA],
            reservedLibraryRoots: [libraryA, libraryB]
        )
        let reconnectedLetters = Dictionary(uniqueKeysWithValues: allReconnected.map {
            ($0.macLibraryURL.standardizedFileURL.path, $0.driveLetter)
        })
        XCTAssertEqual(reconnectedLetters[libraryA.standardizedFileURL.path], letterA)
        XCTAssertEqual(reconnectedLetters[libraryB.standardizedFileURL.path], letterB)

        let afterExplicitRemoval = try steamManager.prepareSteamLibraryDriveLinks(
            prefix: prefix,
            libraryRoots: [libraryB, libraryC],
            reservedLibraryRoots: [libraryB, libraryC]
        )
        let replacementLetters = Dictionary(uniqueKeysWithValues: afterExplicitRemoval.map {
            ($0.macLibraryURL.standardizedFileURL.path, $0.driveLetter)
        })
        XCTAssertEqual(replacementLetters[libraryB.standardizedFileURL.path], letterB)
        XCTAssertEqual(replacementLetters[libraryC.standardizedFileURL.path], letterA)
    }

    func testUnavailableReservedStoragePreservesOwnedSteamRegistrationUntilExplicitRemoval() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayUnavailableRegistrationReservation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let prefix = temporaryRoot.appending(
            path: "Prefix",
            directoryHint: .isDirectory
        )
        let externalLibrary = temporaryRoot.appending(
            path: "External/SteamLibrary",
            directoryHint: .isDirectory
        )
        let steamApps = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: prefix.appending(path: "dosdevices", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalLibrary.appending(
                path: "steamapps",
                directoryHint: .isDirectory
            ),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: steamApps,
            withIntermediateDirectories: true
        )
        try writeSteamLibraryFolderIdentity(
            contentID: "8752980176432109567",
            to: externalLibrary
        )
        let libraryFoldersURL = steamApps.appending(
            path: "libraryfolders.vdf",
            directoryHint: .notDirectory
        )
        try """
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { } }
        }
        """.write(
            to: libraryFoldersURL,
            atomically: true,
            encoding: .utf8
        )

        let mapper = SteamLibraryDriveMapper(
            storageIdentityProvider: { _ in
                "volume-uuid:fixture-unavailable:SteamLibrary"
            }
        )
        let initialMappings = try mapper.prepareDriveLinks(
            prefix: prefix,
            libraryRoots: [externalLibrary],
            reservedLibraryRoots: [externalLibrary]
        )
        try mapper.synchronizeDriveMappingsWithSteam(
            prefix: prefix,
            mappings: initialMappings
        )
        let registrationManifestURL = prefix.appending(
            path: ".forgeplay-library-drives/.steam-library-registrations-v1.json",
            directoryHint: .notDirectory
        )
        let registeredVDF = try Data(contentsOf: libraryFoldersURL)
        let registeredManifest = try Data(contentsOf: registrationManifestURL)

        // The bookmark is temporarily unavailable, but the persisted mount is
        // still present. Its drive reservation must not be treated as a user
        // request to delete the owned Steam registration.
        try FileManager.default.removeItem(
            at: externalLibrary.deletingLastPathComponent()
        )
        _ = try mapper.prepareDriveLinks(
            prefix: prefix,
            libraryRoots: [],
            reservedLibraryRoots: [externalLibrary]
        )
        try mapper.synchronizeDriveMappingsWithSteam(
            prefix: prefix,
            mappings: []
        )
        let reservedAssignment = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: prefix.appending(
                    path: ".forgeplay-library-drives/d/.assignment-v1.json"
                ))
            ) as? [String: Any]
        )
        XCTAssertEqual(reservedAssignment["isReservedOnly"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: libraryFoldersURL), registeredVDF)
        XCTAssertEqual(
            try Data(contentsOf: registrationManifestURL),
            registeredManifest
        )

        // Removing the persisted mount also removes its reservation. Only then
        // is the exact ForgePlay-owned entry eligible for reconciliation.
        _ = try mapper.prepareDriveLinks(
            prefix: prefix,
            libraryRoots: [],
            reservedLibraryRoots: []
        )
        try mapper.synchronizeDriveMappingsWithSteam(
            prefix: prefix,
            mappings: []
        )
        let reconciledText = try XCTUnwrap(
            SteamVDFFileReader.readText(
                libraryFoldersURL,
                maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes
            )
        )
        let reconciledFolders = try XCTUnwrap(
            VDFParser().parse(reconciledText)["libraryfolders"]?.objectValue
        )
        XCTAssertFalse(reconciledFolders.values.contains {
            $0.objectValue?["path"]?.stringValue == "D:\\"
        })
        let reconciledManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: registrationManifestURL)
            ) as? [String: Any]
        )
        XCTAssertTrue(
            (reconciledManifest["ownedRegistrations"] as? [[String: Any]])?
                .isEmpty == true
        )
    }

    func testPrepareSteamLibraryDriveLinksReplacesStaleDirectTargetAfterVolumeRemount() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamDriveRemount-\(UUID().uuidString)", directoryHint: .isDirectory)
        let prefix = temporaryRoot.appending(path: "Prefix", directoryHint: .isDirectory)
        let oldMount = temporaryRoot.appending(path: "OldMount/SteamLibrary", directoryHint: .isDirectory)
        let newMount = temporaryRoot.appending(path: "NewMount/SteamLibrary", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: prefix.appending(path: "dosdevices", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: oldMount, withIntermediateDirectories: true)
        try writeSteamLibraryFolderIdentity(
            contentID: "7652863212217759168",
            to: oldMount
        )

        let mapper = SteamLibraryDriveMapper(
            storageIdentityProvider: { _ in "volume:stable-test-volume:SteamLibrary" }
        )
        let initial = try mapper.prepareDriveLinks(
            prefix: prefix,
            libraryRoots: [oldMount],
            reservedLibraryRoots: [oldMount]
        )
        let letter = try XCTUnwrap(initial.first?.driveLetter)
        let driveLink = prefix.appending(path: "dosdevices/\(letter):")

        try FileManager.default.removeItem(at: oldMount.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: newMount, withIntermediateDirectories: true)
        try writeSteamLibraryFolderIdentity(
            contentID: "7652863212217759168",
            to: newMount
        )
        let reconnected = try mapper.prepareDriveLinks(
            prefix: prefix,
            libraryRoots: [newMount],
            reservedLibraryRoots: [newMount]
        )

        XCTAssertEqual(reconnected.first?.driveLetter, letter)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: driveLink.path)
        XCTAssertEqual(
            URL(fileURLWithPath: target).standardizedFileURL.path,
            newMount.standardizedFileURL.path
        )
        let bridgeRoot = prefix.appending(
            path: ".forgeplay-library-drives/\(letter)",
            directoryHint: .isDirectory
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: bridgeRoot.appending(path: "SteamLibrary").path
            ),
            newMount.standardizedFileURL.path
        )
    }

    func testPrepareSteamLibraryDriveLinksAbandonsConflictingReservationAndUsesNextLetter() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamDriveAssignmentIntegrity-\(UUID().uuidString)", directoryHint: .isDirectory)
        let prefix = temporaryRoot.appending(path: "Prefix", directoryHint: .isDirectory)
        let library = temporaryRoot.appending(path: "SteamLibrary", directoryHint: .isDirectory)
        let unrelatedTarget = temporaryRoot.appending(path: "Unrelated", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let dosdevices = prefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: dosdevices,
            withIntermediateDirectories: true
        )
        for directory in [library, unrelatedTarget] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeSteamLibraryFolderIdentity(
            contentID: "3424479868046944824",
            to: library
        )

        let mapper = SteamLibraryDriveMapper(
            storageIdentityProvider: { _ in "volume:stable-test-volume:SteamLibrary" }
        )
        let initialMappings = try mapper.prepareDriveLinks(
            prefix: prefix,
            libraryRoots: [library],
            reservedLibraryRoots: [library]
        )
        XCTAssertEqual(initialMappings.first?.driveLetter, "d")

        let driveLink = dosdevices.appending(path: "d:")
        try FileManager.default.removeItem(at: driveLink)
        try FileManager.default.createSymbolicLink(
            at: driveLink,
            withDestinationURL: unrelatedTarget
        )

        let remapped = try mapper.prepareDriveLinks(
            prefix: prefix,
            libraryRoots: [library],
            reservedLibraryRoots: [library]
        )

        XCTAssertEqual(remapped.first?.driveLetter, "e")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: driveLink.path),
            unrelatedTarget.path
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: dosdevices.appending(path: "e:").path
            ),
            library.path
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prefix.appending(
                    path: ".forgeplay-library-drives/d",
                    directoryHint: .isDirectory
                ).path
            )
        )
    }

    func testExperimentalGameModeAdmissionPrecedesPrefixMutationTransition() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlayGameModeAdmission-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let systemRegistry = prefix.appending(path: "system.reg")
        let originalRegistry = Data("WINE REGISTRY Version 2\n".utf8)
        try originalRegistry.write(to: systemRegistry)
        var admissionCount = 0
        var mutationTransitionCount = 0
        var executionTransitionCount = 0
        let steamManager = SteamManager(
            pathManager: pathManager,
            runner: makeCuratedRuntimeRunner(),
            gameModeHostLaunchAdmission: {
                admissionCount += 1
                throw GameModeHostCapabilityError.applicationGroupRequired
            }
        )
        let leaseTransition = SteamPrefixExecutionLeaseTransition(
            prepareForMutation: { mutationTransitionCount += 1 },
            prepareForExecution: { executionTransitionCount += 1 }
        )

        do {
            _ = try await steamManager.launchSteam(
                runtimeExecutable: temporaryRoot.appending(
                    path: "missing-runtime/bin/wine"
                ),
                verificationMode: .conformance,
                rendererPolicy: .d3dMetal,
                gameModePolicy: .experimentalRequiredHost,
                prefixExecutionLeaseTransition: leaseTransition
            )
            XCTFail("expected static Game Mode host admission failure")
        } catch {
            XCTAssertEqual(
                error as? GameModeHostCapabilityError,
                .applicationGroupRequired
            )
        }

        XCTAssertEqual(admissionCount, 1)
        XCTAssertEqual(mutationTransitionCount, 0)
        XCTAssertEqual(executionTransitionCount, 0)
        XCTAssertEqual(try Data(contentsOf: systemRegistry), originalRegistry)
    }

    func testLaunchSteamStartsWindowsSteamInVirtualDesktopAndLinksLibraryRoot() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamLaunchRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLibrary = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalSteamLibrary-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            try? FileManager.default.removeItem(at: externalLibrary)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let runtimeRoot = temporaryRoot.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcherDirectory = runtimeRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        let invocationLog = temporaryRoot.appending(path: "steam-launch-invocations.log")
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        let steamApps = steamDirectory.appending(path: "steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)
        try """
        "libraryfolders"
        {
            "0"
            {
                "path" "C:\\\\Program Files (x86)\\\\Steam"
                "apps" { }
            }
        }
        """.write(
            to: steamApps.appending(path: "libraryfolders.vdf"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try FileManager.default.createDirectory(
            at: externalLibrary.appending(path: "steamapps", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try writeSteamLibraryFolderIdentity(
            contentID: "7087413303042538736",
            to: externalLibrary
        )
        try writeManifest(
            appId: "220",
            name: "Half-Life 2",
            installDir: "Half-Life 2",
            to: externalLibrary.appending(path: "steamapps/appmanifest_220.acf")
        )
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        printf 'WINEDLLOVERRIDES=%s\\n' "$WINEDLLOVERRIDES"
        printf 'WINEPREFIX=%s\\n' "$WINEPREFIX"
        printf 'WINEESYNC=%s\\n' "$WINEESYNC"
        printf 'MTL_HUD_ENABLED=%s\\n' "$MTL_HUD_ENABLED"
        printf 'WINEDLLPATH=%s\\n' "$WINEDLLPATH"
        printf 'D3DMETAL_FRAMEWORK_PATH=%s\\n' "$D3DMETAL_FRAMEWORK_PATH"
        printf 'VK_ICD_FILENAMES=%s\\n' "$VK_ICD_FILENAMES"
        printf '%s\\n' "$@"
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try await applySteamLaunchPolicy(steamManager: steamManager, prefix: prefix, launcher: launcher)
        try? FileManager.default.removeItem(at: invocationLog)

        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .conformance,
            rendererPolicy: .d3dMetal,
            libraryRoots: [externalLibrary]
        )
        let output = try String(contentsOf: result.stdoutLog, encoding: .utf8)
        let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.processExitCode, 0)
        XCTAssertEqual(result.forgePlayStatusCode, SteamManager.steamUIStartupFailureExitCode)
        XCTAssertNotNil(result.diagnosticLog)
        XCTAssertTrue(invocations.contains("--version"), invocations.joined(separator: "\n"))
        XCTAssertTrue(
            invocations.contains("wineserver --kill=\(SIGTERM)"),
            invocations.joined(separator: "\n")
        )
        let profileInspection = SteamClientCompatibilityProfileContract.inspect(prefix: prefix)
        XCTAssertTrue(profileInspection.isSatisfied, profileInspection.missingOverrides.joined(separator: "\n"))
        XCTAssertTrue(
            profileInspection.appliedOverrides.contains { $0.contains("gameoverlayrenderer=<empty>") },
            profileInspection.appliedOverrides.joined(separator: "\n")
        )
        XCTAssertTrue(profileInspection.staleOverrides.isEmpty, profileInspection.staleOverrides.joined(separator: "\n"))
        XCTAssertFalse(invocations.contains { $0.contains("explorer /desktop=ForgePlaySteam,1280x800") })
        XCTAssertTrue(invocations.contains { $0.contains("C:\\Program Files (x86)\\Steam\\steam.exe") })
        XCTAssertFalse(invocations.contains { $0.contains("launch-steam.bat") })
        XCTAssertTrue(output.contains("WINEPREFIX=\(prefix.path)"))
        XCTAssertTrue(output.contains("WINEESYNC=\n"))
        XCTAssertTrue(output.contains("MTL_HUD_ENABLED=0"))
        let stdoutLines = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertTrue(output.contains("WINEDLLOVERRIDES="), output)
        XCTAssertFalse(output.contains("winemetal=n,b"), output)
        XCTAssertFalse(output.contains("d3d11,dxgi,d3d12,d3d12core=n,b"), output)
        XCTAssertFalse(output.contains("vulkan-1=d"))
        XCTAssertTrue(output.contains("WINEDLLPATH="), output)
        XCTAssertFalse(output.contains("WINEDLLPATH=\(renderer.path)"), output)
        XCTAssertTrue(output.contains("D3DMETAL_FRAMEWORK_PATH="), output)
        XCTAssertFalse(output.contains("D3DMetal.framework/D3DMetal"), output)
        XCTAssertTrue(output.contains("VK_ICD_FILENAMES="), output)
        XCTAssertFalse(stdoutLines.contains("-udpforce"))
        XCTAssertFalse(stdoutLines.contains("-allosarches"))
        XCTAssertFalse(stdoutLines.contains("-noreactlogin"))
        XCTAssertFalse(stdoutLines.contains("-no-browser"))
        XCTAssertFalse(stdoutLines.contains("-cef-force-32bit"))
        XCTAssertFalse(stdoutLines.contains("+open"))
        XCTAssertFalse(stdoutLines.contains("steam://open/minigameslist"))
        XCTAssertFalse(stdoutLines.contains("-cef-in-process-gpu"))
        XCTAssertTrue(stdoutLines.contains("-no-cef-sandbox"))
        XCTAssertFalse(stdoutLines.contains("-cef-disable-seccomp-sandbox"))
        XCTAssertFalse(stdoutLines.contains("-cef-disable-gpu-sandbox"))
        XCTAssertFalse(stdoutLines.contains("-cef-disable-gpu"))
        XCTAssertFalse(stdoutLines.contains("-cef-disable-gpu-compositing"))
        XCTAssertFalse(stdoutLines.contains("-cef-use-gl=angle"))
        XCTAssertFalse(stdoutLines.contains("-cef-use-angle=d3d11"))
        XCTAssertFalse(stdoutLines.contains("-cef-disable-software-rasterizer"))
        XCTAssertFalse(stdoutLines.contains("-cef-force-gpu"))
        XCTAssertFalse(stdoutLines.contains("-cef-force-opaque-backgrounds"))
        XCTAssertTrue(output.contains("C:\\Program Files (x86)\\Steam\\steam.exe"))
        XCTAssertFalse(output.contains("C:\\ForgePlay\\Launchers\\launch-steam.bat"))
        XCTAssertFalse(output.contains("explorer"))
        XCTAssertFalse(output.contains("/desktop=ForgePlaySteam,1280x800"))
        XCTAssertFalse(stdoutLines.contains("-cef-disable-vulkan"))
        XCTAssertFalse(stdoutLines.contains("-cef-disable-features=Vulkan,VulkanFromANGLE,DefaultANGLEVulkan"))
        XCTAssertFalse(stdoutLines.contains("-disable-vulkan"))
        XCTAssertEqual(
            SteamManager.mappedWindowsLibraryPath(
                for: externalLibrary,
                prefix: prefix
            ),
            "D:\\"
        )
        let bridgeDirectory = prefix.appending(
            path: ".forgeplay-library-drives",
            directoryHint: .isDirectory
        )
        let bridgeRoots = try FileManager.default.contentsOfDirectory(
            at: bridgeDirectory,
            includingPropertiesForKeys: nil
        )
        let linkedTargets = bridgeRoots.compactMap { bridgeRoot in
            try? FileManager.default.destinationOfSymbolicLink(
                atPath: bridgeRoot.appending(path: "SteamLibrary").path
            )
        }
        XCTAssertTrue(linkedTargets.contains(externalLibrary.path), linkedTargets.joined(separator: "\n"))
        let libraryFoldersURL = steamApps.appending(path: "libraryfolders.vdf")
        let libraryFoldersText = try XCTUnwrap(
            try SteamVDFFileReader.readText(
                libraryFoldersURL,
                maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes
            )
        )
        let libraryFolders = try XCTUnwrap(
            VDFParser().parse(libraryFoldersText)["libraryfolders"]?.objectValue
        )
        let registeredPaths = libraryFolders.values.compactMap {
            $0.objectValue?["path"]?.stringValue
        }
        XCTAssertEqual(
            Set(registeredPaths),
            Set(["C:\\Program Files (x86)\\Steam", "D:\\"])
        )
    }

    func testLaunchSteamPreflightAppliesMissingSteamClientProfileAndRendererPolicy() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamLaunchPreflightRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        var servicePreparationCallCount = 0
        let steamManager = makeSteamManager(
            pathManager: pathManager,
            steamClientServicePreparer: { _, _, _ in
                servicePreparationCallCount += 1
            }
        )
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let runtimeRoot = temporaryRoot.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcherDirectory = runtimeRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        let invocationLog = temporaryRoot.appending(path: "steam-launch-preflight-invocations.log")
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        \(steamRegistryRecordingShellPreamble())
        if [ "$1" = "wineserver" ]; then
          exit 0
        fi
        printf 'WINEPREFIX=%s\\n' "$WINEPREFIX"
        printf '%s\\n' "$@"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let beforeLaunch = steamManager.inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: launcher,
            selection: .d3dMetal
        )
        XCTAssertEqual(beforeLaunch.status, .warning)
        XCTAssertTrue(beforeLaunch.requiresApply)

        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .conformance,
            rendererPolicy: .d3dMetal
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.processExitCode, 0)
        XCTAssertEqual(result.forgePlayStatusCode, SteamManager.steamUIStartupFailureExitCode)
        XCTAssertNotNil(result.diagnosticLog)
        let didReleasePrefixAfterInitialLaunch = try await steamManager
            .waitForCompatibilityPrefixToBecomeInactive(prefix)
        XCTAssertTrue(
            didReleasePrefixAfterInitialLaunch,
            "renderer inspection and mutation require an inactive prefix"
        )
        let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
        XCTAssertTrue(invocations.contains("wineserver --kill=\(SIGTERM)"), invocations)
        XCTAssertTrue(invocations.contains("reg add HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug"), invocations)
        XCTAssertFalse(
            invocations.contains("reg delete \"HKCU\\Software\\Wine\\AppDefaults\\steamwebhelper.exe\\DllOverrides\""),
            "Preflight must not issue delete commands for absent per-application overrides:\n\(invocations)"
        )
        XCTAssertTrue(invocations.contains("C:\\Program Files (x86)\\Steam\\steam.exe"), invocations)
        XCTAssertTrue(invocations.contains("-no-cef-sandbox"), invocations)
        XCTAssertFalse(invocations.contains("-cef-disable-gpu"), invocations)
        XCTAssertFalse(invocations.contains("-cef-disable-gpu-compositing"), invocations)
        XCTAssertFalse(invocations.contains("launch-steam.bat"), invocations)

        let afterLaunch = steamManager.inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: launcher,
            selection: .d3dMetal
        )
        XCTAssertEqual(afterLaunch.status, .ok, afterLaunch.userMessage)
        XCTAssertFalse(afterLaunch.requiresApply)
        XCTAssertTrue(afterLaunch.missingProfileOverrides.isEmpty, afterLaunch.missingProfileOverrides.joined(separator: "\n"))
        XCTAssertTrue(afterLaunch.missingModules.isEmpty, afterLaunch.missingModules.joined(separator: "\n"))

        _ = try SteamRendererPolicyManager()
            .stageNVIDIAMetalFXBridgeModules(
                prefix: prefix,
                runtimeExecutable: launcher
            )
        let rendererWindows = renderer.appending(
            path: "wine/x86_64-windows",
            directoryHint: .isDirectory
        )
        let updatedNVAPI = Data("updated runtime nvapi".utf8)
        for moduleName in ["nvapi.dll", "nvapi64.dll"] {
            try updatedNVAPI.write(
                to: rendererWindows.appending(path: moduleName),
                options: .atomic
            )
        }
        try Data("updated runtime nvngx".utf8).write(
            to: rendererWindows.appending(path: "nvngx-on-metalfx.dll"),
            options: .atomic
        )
        let priorNVIDIAResidue = steamManager.inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: launcher,
            selection: .d3dMetal
        )
        XCTAssertTrue(
            SteamRendererPolicyManager()
                .isRecoverableNVIDIAMetalFXSessionResidue(
                    priorNVIDIAResidue,
                    prefix: prefix,
                    runtimeExecutable: launcher
                ),
            priorNVIDIAResidue.mixedModules.joined(separator: "\n")
        )
        let restartReadinessInspection = steamManager
            .inspectSteamRendererPolicyForReadiness(
                prefix: prefix,
                runtimeExecutable: launcher,
                selection: .d3dMetal
            )
        XCTAssertEqual(restartReadinessInspection.status, .warning)
        XCTAssertEqual(
            restartReadinessInspection.effectiveRecoveryKind,
            .automaticSessionRecovery
        )
        XCTAssertFalse(restartReadinessInspection.requiresRepair)
        XCTAssertFalse(restartReadinessInspection.allowsRecoveryAction)
        let stagedNVNGX = prefix.appending(
            path: "drive_c/windows/system32/nvngx.dll"
        )
        let exactStagedNVNGX = try Data(contentsOf: stagedNVNGX)
        try Data("mismatched staged nvngx".utf8).write(
            to: stagedNVNGX,
            options: .atomic
        )
        let mismatchedRestartReadiness = steamManager
            .inspectSteamRendererPolicyForReadiness(
                prefix: prefix,
                runtimeExecutable: launcher,
                selection: .d3dMetal
            )
        XCTAssertEqual(mismatchedRestartReadiness.status, .error)
        XCTAssertEqual(
            mismatchedRestartReadiness.effectiveRecoveryKind,
            .repairPolicy
        )
        XCTAssertTrue(mismatchedRestartReadiness.requiresRepair)
        try exactStagedNVNGX.write(to: stagedNVNGX, options: .atomic)
        XCTAssertEqual(
            steamManager.inspectSteamRendererPolicyForReadiness(
                prefix: prefix,
                runtimeExecutable: launcher,
                selection: .d3dMetal
            ).effectiveRecoveryKind,
            .automaticSessionRecovery
        )

        _ = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .conformance,
            rendererPolicy: .d3dMetal
        )
        let didReleasePrefixAfterNormalization = try await steamManager
            .waitForCompatibilityPrefixToBecomeInactive(prefix)
        XCTAssertTrue(
            didReleasePrefixAfterNormalization,
            "the completed fixture launch must release the prefix before readback"
        )
        let afterResidueNormalization =
            steamManager.inspectSteamRendererPolicy(
                prefix: prefix,
                runtimeExecutable: launcher,
                selection: .d3dMetal
            )
        XCTAssertEqual(
            afterResidueNormalization.status,
            .ok,
            afterResidueNormalization.userMessage
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prefix.appending(
                    path: "drive_c/windows/system32/nvapi.dll"
                ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prefix.appending(
                    path: "drive_c/windows/system32/nvapi64.dll"
                ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prefix.appending(
                    path: "drive_c/windows/system32/nvngx.dll"
                ).path
            )
        )
        XCTAssertEqual(servicePreparationCallCount, 2)

        let inputProtection = DetachedHandoffInputProtectionDriver()
        let preparationFailureManager = makeSteamManager(
            pathManager: pathManager,
            gameInputProtectionDriverFactory: { inputProtection },
            gameInputProtectionPolicyStore: GameInputProtectionPolicyStore(
                initialPolicy: GameInputProtectionPolicy(
                    blockAppSwitchingShortcuts: true
                )
            ),
            steamClientServicePreparer: { _, _, _ in
                throw CocoaError(.fileReadUnknown)
            }
        )
        do {
            _ = try await preparationFailureManager.launchSteam(
                runtimeExecutable: launcher,
                verificationMode: .conformance,
                rendererPolicy: .d3dMetal
            )
            XCTFail("Steam service preparation failure must stop launch")
        } catch {
            XCTAssertEqual(
                (error as? CocoaError)?.code,
                CocoaError.Code.fileReadUnknown
            )
        }
        XCTAssertEqual(
            inputProtection.prepareCallCount,
            0,
            "host input protection must not start before Steam service preparation succeeds"
        )
        XCTAssertNil(inputProtection.boundProcessIdentifier)
        XCTAssertEqual(
            inputProtection.restoreCallCount,
            1,
            "session deinitialization performs a resource-free restore even when preparation never started"
        )
    }

    func testConformanceLaunchBlocksWithoutTerminatingHostSteam() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamHostCleanupRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let runtimeRoot = temporaryRoot.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcherDirectory = runtimeRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        let invocationLog = temporaryRoot.appending(path: "steam-launch-host-cleanup-invocations.log")
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        \(steamRegistryRecordingShellPreamble())
        if [ "$1" = "--version" ]; then
          printf 'wine-11.12\\n'
          exit 0
        fi
        if [ "$1" = "cmd" ] && [ "$2" = "/c" ]; then
          printf 'Microsoft Windows [Version 10.0.19045]\\n'
          exit 0
        fi
        if [ "$1" = "wineserver" ]; then
          exit 0
        fi
        printf 'WINEPREFIX=%s\\n' "$WINEPREFIX"
        printf '%s\\n' "$@"
        case "$*" in
          *"steam.exe"*) exit 42 ;;
        esac
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let hostSteamSnapshot = SteamLaunchProcessSnapshot(processes: [
                SteamLaunchObservedProcess(
                    processID: 99999,
                    command: "/Users/tester/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/ipcserver"
                )
            ])
        let steamManager = makeSteamManager(pathManager: pathManager) { hostSteamSnapshot }

        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .conformance,
            rendererPolicy: .d3dMetal
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.processExitCode)
        XCTAssertEqual(result.forgePlayStatusCode, SteamManager.steamLaunchBlockedExitCode)
        XCTAssertNotNil(result.diagnosticLog)
        let invocations = (try? String(contentsOf: invocationLog, encoding: .utf8)) ?? ""
        XCTAssertFalse(invocations.contains("C:\\Program Files (x86)\\Steam\\steam.exe"), invocations)
        let diagnostics = try result.diagnosticLog.map { try String(contentsOf: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(diagnostics.contains("blocked-host-steam-running"), diagnostics)
        XCTAssertTrue(diagnostics.contains("Windows Steam launch did not start because preflight returned BLOCKED"), diagnostics)
    }

    func testLaunchSteamRejectsRuntimeWithUnsupportedSteamCEFChildWindowRendererBeforeStartingProcess() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamLaunchRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let runnerRoot = temporaryRoot.appending(path: "ForgePlayRuntime", directoryHint: .isDirectory)
        let launcherDirectory = runnerRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let wineRoot = runnerRoot.appending(path: "wine", directoryHint: .isDirectory)
        let wineMacUnixDirectory = wineRoot.appending(path: "lib/wine/x86_64-unix", directoryHint: .isDirectory)
        let renderer = runnerRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        let invocationLog = temporaryRoot.appending(path: "steam-launch-should-not-run.log")
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wineMacUnixDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try Data("Cross-process child window Metal swapchains are not implemented".utf8)
            .write(to: wineMacUnixDirectory.appending(path: "winemac.so"))
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .conformance,
            rendererPolicy: .d3dMetal
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.processExitCode)
        XCTAssertEqual(result.forgePlayStatusCode, SteamManager.steamLaunchBlockedExitCode)
        let diagnosticLog = try XCTUnwrap(result.diagnosticLog)
        let manifest = try String(
            contentsOf: diagnosticLog
                .deletingPathExtension()
                .appendingPathExtension("diagnostics")
                .appending(path: "manifest.json"),
            encoding: .utf8
        )
        XCTAssertTrue(manifest.contains(#""status" : "BLOCKED""#), manifest)
        XCTAssertTrue(manifest.contains("blocked-runner-preflight-failed"), manifest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocationLog.path))
    }

    func testLaunchSteamRejectsMissingSteamExecutableBeforeStartingProcess() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamLaunchRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let runnerRoot = temporaryRoot.appending(path: "ForgePlayRuntime", directoryHint: .isDirectory)
        let launcherDirectory = runnerRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let wineRoot = runnerRoot.appending(path: "wine", directoryHint: .isDirectory)
        let renderer = runnerRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        let invocationLog = temporaryRoot.appending(path: "steam-launch-missing-steam-should-not-run.log")

        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let expectedSteamExecutable = steamDirectory.appending(path: "steam.exe")
        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .conformance,
            rendererPolicy: .d3dMetal
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.processExitCode)
        XCTAssertEqual(result.forgePlayStatusCode, SteamManager.steamLaunchBlockedExitCode)
        let diagnosticLog = try XCTUnwrap(result.diagnosticLog)
        let diagnostics = try String(contentsOf: diagnosticLog, encoding: .utf8)
        XCTAssertTrue(diagnostics.contains(expectedSteamExecutable.path), diagnostics)
        XCTAssertTrue(diagnostics.contains("blocked-runner-preflight-failed"), diagnostics)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocationLog.path))
    }

    func testLaunchSteamKeepsGameRendererOutOfSteamClientAndKeepsBaseMoltenVKAvailable() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamLaunchRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let system32 = prefix.appending(path: "drive_c/windows/system32", directoryHint: .isDirectory)
        let runnerRoot = temporaryRoot.appending(path: "ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runnerRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcherDirectory = runnerRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let runtimeLib = wineRoot.appending(path: "lib", directoryHint: .isDirectory)
        let icdDirectory = wineRoot.appending(path: "etc/vulkan/icd.d", directoryHint: .isDirectory)
        let renderer = runnerRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimeLib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: icdDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try Data().write(to: runtimeLib.appending(path: "libgnutls.30.dylib"))
        try Data().write(to: runtimeLib.appending(path: "libfreetype.6.dylib"))
        try Data().write(to: runtimeLib.appending(path: "libvulkan.1.dylib"))
        try Data().write(to: runtimeLib.appending(path: "libMoltenVK.dylib"))
        try #"{"ICD":{"library_path":"../../lib/libMoltenVK.dylib","api_version":"1.4.0"}}"#
            .write(to: icdDirectory.appending(path: "MoltenVK_icd.json"), atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        env | sort
        printf '%s\\n' "$@"
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try await applySteamLaunchPolicy(steamManager: steamManager, prefix: prefix, launcher: launcher)

        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .conformance,
            rendererPolicy: .d3dMetal
        )
        let output = try String(contentsOf: result.stdoutLog, encoding: .utf8)
        let errorOutput = try String(contentsOf: result.stderrLog, encoding: .utf8)
        let outputLines = output.split(whereSeparator: \.isNewline).map(String.init)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.processExitCode, 0)
        XCTAssertEqual(
            result.forgePlayStatusCode,
            SteamManager.steamUIStartupFailureExitCode,
            errorOutput
        )
        XCTAssertNotNil(result.diagnosticLog)
        XCTAssertTrue(output.contains("WINEPREFIX=\(prefix.path)"))
        XCTAssertFalse(outputLines.contains { $0.hasPrefix("WINEDLLOVERRIDES=") }, output)
        XCTAssertFalse(outputLines.contains { $0.hasPrefix("D3DMETAL_FRAMEWORK_PATH=") }, output)
        XCTAssertTrue(outputLines.contains("FORGEPLAY_GAME_RENDERER_POLICY_ENABLED=1"), output)
        XCTAssertTrue(outputLines.contains("FORGEPLAY_GAME_RENDERER_POLICY=d3dMetal"), output)
        XCTAssertTrue(output.contains("FORGEPLAY_GAME_RENDERER_DLL_PATH_X64=Z:"), output)
        XCTAssertTrue(
            outputLines.contains("FORGEPLAY_GAME_RENDERER_DLL_PATH_X86="),
            output
        )
        XCTAssertTrue(output.contains("FORGEPLAY_GAME_RENDERER_ENV_WINEDLLOVERRIDES="), output)
        XCTAssertTrue(output.contains("FORGEPLAY_GAME_RENDERER_ENV_D3DMETAL_FRAMEWORK_PATH="), output)
        XCTAssertTrue(
            outputLines.contains(
                "FORGEPLAY_GAME_RENDERER_ENV_D3DM_ENABLE_METALFX=__FORGEPLAY_UNSET__"
            ),
            output
        )
        XCTAssertTrue(
            outputLines.contains(
                "FORGEPLAY_GAME_RENDERER_ENV_D3DM_NVNGX_PATH=__FORGEPLAY_UNSET__"
            ),
            output
        )
        XCTAssertFalse(outputLines.contains { $0.hasPrefix("D3DM_ENABLE_METALFX=") }, output)
        XCTAssertFalse(outputLines.contains { $0.hasPrefix("D3DM_NVNGX_PATH=") }, output)
        XCTAssertTrue(output.contains("renderer/d3dmetal"), output)
        XCTAssertTrue(output.contains("VK_ICD_FILENAMES="), output)
        XCTAssertTrue(output.contains("VK_DRIVER_FILES="), output)
        XCTAssertFalse(outputLines.contains("VK_ICD_FILENAMES=/dev/null"), output)
        XCTAssertFalse(outputLines.contains("VK_DRIVER_FILES=/dev/null"), output)
        XCTAssertTrue(output.contains("wine/etc/vulkan/icd.d/MoltenVK_icd.json"), output)
        XCTAssertFalse(output.lowercased().contains("applaunch"))
        XCTAssertFalse(output.lowercased().contains("rungameid"))
        XCTAssertFalse(output.contains("steam://open/minigameslist"))
        XCTAssertTrue(output.contains("C:\\Program Files (x86)\\Steam\\steam.exe"))
        XCTAssertFalse(output.contains("explorer"))
        XCTAssertFalse(output.contains("/desktop=ForgePlaySteam,1280x800"))
    }

    func testLaunchSteamBlocksRepairRequiredRendererStateWithoutMutatingIt() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamLaunchRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let system32 = prefix.appending(path: "drive_c/windows/system32", directoryHint: .isDirectory)
        let syswow64 = prefix.appending(path: "drive_c/windows/syswow64", directoryHint: .isDirectory)
        let runnerRoot = temporaryRoot.appending(path: "ForgePlayRuntime", directoryHint: .isDirectory)
        let launcherDirectory = runnerRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let wineRoot = runnerRoot.appending(path: "wine", directoryHint: .isDirectory)
        let renderer = runnerRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let rendererWindows = renderer.appending(path: "wine/x86_64-windows", directoryHint: .isDirectory)
        let dxvkRendererWindows = runnerRoot
            .appending(path: "Frameworks/renderer/dxvk/wine/x86_64-windows", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        _ = try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dxvkRendererWindows, withIntermediateDirectories: true)
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try Data("original d3d11".utf8).write(to: system32.appending(path: "d3d11.dll"))
        try Data("DXVK stale d3d9".utf8).write(to: system32.appending(path: "d3d9.dll"))
        try Data("D3DMetal stale syswow64 d3d11".utf8).write(to: syswow64.appending(path: "d3d11.dll"))
        try Data("DXVK stale syswow64 dxgi".utf8).write(to: syswow64.appending(path: "dxgi.dll"))
        let backupDirectory = prefix.appending(path: "drive_c/ForgePlay/RendererBackups/system32", directoryHint: .isDirectory)
        let syswow64BackupDirectory = prefix.appending(path: "drive_c/ForgePlay/RendererBackups/syswow64", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syswow64BackupDirectory, withIntermediateDirectories: true)
        try Data("original d3d9".utf8).write(to: backupDirectory.appending(path: "d3d9.dll.original"))
        try Data("original syswow64 d3d11".utf8).write(to: syswow64BackupDirectory.appending(path: "d3d11.dll.original"))
        try Data("original syswow64 dxgi".utf8).write(to: syswow64BackupDirectory.appending(path: "dxgi.dll.original"))
        try Data("metal d3d9".utf8).write(to: rendererWindows.appending(path: "d3d9.dll"))
        try Data("metal d3d11".utf8).write(to: rendererWindows.appending(path: "d3d11.dll"))
        try Data("metal dxgi".utf8).write(to: rendererWindows.appending(path: "dxgi.dll"))
        try Data("dxvk d3d9".utf8).write(to: dxvkRendererWindows.appending(path: "d3d9.dll"))
        try Data("dxvk d3d11".utf8).write(to: dxvkRendererWindows.appending(path: "d3d11.dll"))
        try Data("dxvk dxgi".utf8).write(to: dxvkRendererWindows.appending(path: "dxgi.dll"))
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        _ = try await steamManager.applySteamClientCompatibilityProfile(
            runtimeExecutable: launcher,
            prefix: prefix
        )
        let repairRequired = steamManager.inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: launcher,
            selection: .d3dMetal
        )
        XCTAssertEqual(repairRequired.status, .error)
        XCTAssertTrue(repairRequired.requiresRepair)
        XCTAssertFalse(
            SteamRendererPolicyManager()
                .isRecoverableNVIDIAMetalFXSessionResidue(
                    repairRequired,
                    prefix: prefix,
                    runtimeExecutable: launcher
                )
        )
        let restartReadinessInspection = steamManager
            .inspectSteamRendererPolicyForReadiness(
                prefix: prefix,
                runtimeExecutable: launcher,
                selection: .d3dMetal
            )
        XCTAssertEqual(restartReadinessInspection.status, .error)
        XCTAssertEqual(
            restartReadinessInspection.effectiveRecoveryKind,
            .repairPolicy
        )
        XCTAssertTrue(restartReadinessInspection.requiresRepair)
        XCTAssertTrue(restartReadinessInspection.allowsRecoveryAction)

        do {
            _ = try await steamManager.launchSteam(
                runtimeExecutable: launcher,
                verificationMode: .conformance,
                rendererPolicy: .d3dMetal
            )
            XCTFail("Repair-required renderer contamination must block Steam launch")
        } catch SteamLaunchError.rendererPolicyVerificationFailed(let message) {
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("Unexpected launch error: \(error)")
        }
        let stillRepairRequired = steamManager.inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: launcher,
            selection: .d3dMetal
        )
        XCTAssertEqual(stillRepairRequired.status, .error)
        XCTAssertTrue(stillRepairRequired.requiresRepair)
        XCTAssertEqual(
            try String(contentsOf: system32.appending(path: "d3d11.dll"), encoding: .utf8),
            "original d3d11"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: system32.appending(path: "dxgi.dll").path))
        XCTAssertEqual(
            try String(contentsOf: system32.appending(path: "d3d9.dll"), encoding: .utf8),
            "DXVK stale d3d9"
        )
        XCTAssertEqual(
            try String(contentsOf: syswow64.appending(path: "d3d11.dll"), encoding: .utf8),
            "D3DMetal stale syswow64 d3d11"
        )
        XCTAssertEqual(
            try String(contentsOf: syswow64.appending(path: "dxgi.dll"), encoding: .utf8),
            "DXVK stale syswow64 dxgi"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: backupDirectory.appending(path: "d3d9.dll.original").path
            )
        )
    }

    func testRendererLifecycleWrapperPreservesStructuredPhaseOperationAndEvidence() {
        func processResult(_ name: String, sequence: TimeInterval) -> ProcessRunResult {
            ProcessRunResult(
                actionName: name,
                executable: URL(fileURLWithPath: "/fixture/wine"),
                arguments: [],
                startedAt: Date(timeIntervalSince1970: sequence),
                endedAt: Date(timeIntervalSince1970: sequence + 1),
                exitCode: 1,
                stdoutLog: URL(fileURLWithPath: "/fixture/\(name)-stdout.log"),
                stderrLog: URL(fileURLWithPath: "/fixture/\(name)-stderr.log"),
                didTimeOut: false
            )
        }

        let originalResult = processResult("registry-flush", sequence: 1)
        let wrapperResult = processResult("wrapper-evidence", sequence: 2)
        let rollbackResult = processResult("rollback-evidence", sequence: 3)
        let originalTarget = URL(fileURLWithPath: "/fixture/system.reg")
        let originalFailure = SteamRendererLifecycleFailure(
            phase: .preparationRollback,
            operation: .ngxCoreRegistryFlush,
            target: originalTarget,
            detail: "flush barrier timed out",
            processResults: [originalResult]
        )
        let wrappedError = ProcessExecutionEvidenceError(
            underlyingError: SteamLaunchError.rendererLifecycleFailed(
                originalFailure
            ),
            result: wrapperResult
        )

        let preserved = SteamManager
            .rendererLifecycleFailurePreservingStructuredError(
                wrappedError,
                fallbackPhase: .preparation,
                fallbackOperation: .ngxCoreFullPathRegistration,
                fallbackTarget: URL(fileURLWithPath: "/wrong-prefix"),
                additionalDetail: "module rollback also failed",
                additionalProcessResults: [rollbackResult]
            )

        XCTAssertEqual(preserved.phase, .preparationRollback)
        XCTAssertEqual(preserved.operation, .ngxCoreRegistryFlush)
        XCTAssertEqual(preserved.target, originalTarget)
        XCTAssertEqual(
            preserved.detail,
            "flush barrier timed out; module rollback also failed"
        )
        XCTAssertEqual(
            preserved.processResults,
            [originalResult, wrapperResult, rollbackResult]
        )
    }

    func testNVIDIAMetalFXStageUsesSystem32AndRestoresPrefixOriginals() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlayMetalFXSystem32-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let runtimeRoot = temporaryRoot.appending(
            path: "ForgePlayRuntime",
            directoryHint: .isDirectory
        )
        let launcher = runtimeRoot.appending(path: "wine/bin/wine")
        let renderer = runtimeRoot.appending(
            path: "Frameworks/renderer/d3dmetal",
            directoryHint: .isDirectory
        )
        let prefix = temporaryRoot.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let system32 = prefix.appending(
            path: "drive_c/windows/system32",
            directoryHint: .isDirectory
        )
        let logDirectory = temporaryRoot.appending(
            path: "Logs",
            directoryHint: .isDirectory
        )
        let invocationLog = temporaryRoot.appending(
            path: "wine-invocations.log",
            directoryHint: .notDirectory
        )
        let syswow64 = prefix.appending(
            path: "drive_c/windows/syswow64",
            directoryHint: .isDirectory
        )
        let originalNVAPI = Data("prefix original nvapi".utf8)
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: system32,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: syswow64,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        \(steamRegistryRecordingShellPreamble())
        exit 0
        """.write(
            to: launcher,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        try writeD3DMetalRenderer(at: renderer)
        try "WINE REGISTRY Version 2\n".write(
            to: prefix.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try originalNVAPI.write(
            to: system32.appending(path: "nvapi64.dll")
        )

        let restorationFailureFileManager =
            RendererRestorationRetirementFailureFileManager()
        let manager = SteamRendererPolicyManager(
            fileManager: restorationFailureFileManager
        )
        let runner = makeCuratedRuntimeRunner()
        XCTAssertEqual(
            try manager.stageNVIDIAMetalFXBridgeModules(
                prefix: prefix,
                runtimeExecutable: launcher
            ),
            ["nvapi.dll", "nvapi64.dll", "nvngx.dll"]
        )
        try await manager.stageNVIDIAMetalFXRegistrySession(
            prefix: prefix,
            runtimeExecutable: launcher,
            runner: runner,
            logDirectory: logDirectory
        )

        let sourceNVAPIAlias = renderer.appending(
            path: D3DMetalNVAPIAliasContract.windowsAliasRelativePath
        )
        let sourceNVAPI = renderer.appending(
            path: "wine/x86_64-windows/nvapi64.dll"
        )
        let sourceNGX = renderer.appending(
            path: "wine/x86_64-windows/nvngx-on-metalfx.dll"
        )
        let stagedNVAPIAlias = system32.appending(path: "nvapi.dll")
        let stagedNVAPI = system32.appending(path: "nvapi64.dll")
        let stagedNGX = system32.appending(path: "nvngx.dll")
        let backupDirectory = prefix.appending(
            path: "drive_c/ForgePlay/RendererBackups/system32",
            directoryHint: .isDirectory
        )
        let moduleSessionDirectory = backupDirectory.appending(
            path: ".forgeplay-nvidia-metalfx-session",
            directoryHint: .isDirectory
        )
        XCTAssertEqual(
            try Data(contentsOf: stagedNVAPIAlias),
            try Data(contentsOf: sourceNVAPIAlias)
        )
        XCTAssertEqual(
            try Data(contentsOf: stagedNVAPI),
            try Data(contentsOf: sourceNVAPI)
        )
        XCTAssertEqual(
            try Data(contentsOf: stagedNGX),
            try Data(contentsOf: sourceNGX)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: moduleSessionDirectory.appending(
                    path: "destination-nvapi64.dll.original"
                )
            ),
            originalNVAPI
        )
        for moduleName in ["nvapi.dll", "nvapi64.dll", "nvngx.dll"] {
            XCTAssertTrue(
                FileSystemItemPolicy.isRegularNonSymlinkFile(
                    moduleSessionDirectory.appending(
                        path: "staged-\(moduleName)"
                    )
                )
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: moduleSessionDirectory.appending(
                    path: "destination-nvapi.dll.original"
                ).path
            )
        )
        let stagedSystemRegistry = try String(
            contentsOf: prefix.appending(path: "system.reg"),
            encoding: .utf8
        )
        XCTAssertEqual(
            WineUserRegistrySnapshot(contents: stagedSystemRegistry).value(
                forRegistryPath:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreRegistryPath,
                valueName:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreFullPathValueName
            ),
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreSystem32Path
        )
        XCTAssertEqual(
            WineUserRegistrySnapshot(contents: stagedSystemRegistry).value(
                forRegistryPath:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreNativeRegistryPath,
                valueName:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreFullPathValueName
            ),
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreSystem32Path
        )
        XCTAssertEqual(
            WineUserRegistrySnapshot(contents: stagedSystemRegistry).value(
                forRegistryPath:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXDriverRegistryPath,
                valueName:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXDriverPathValueName
            ),
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreSystem32Path
        )
        let registryMarker = prefix.appending(
            path:
                "drive_c/ForgePlay/RendererBackups/" +
                SteamRendererPolicyManager
                    .nvidiaMetalFXRegistrySessionMarkerName
        )
        XCTAssertTrue(
            FileSystemItemPolicy.isRegularNonSymlinkFile(registryMarker)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: moduleSessionDirectory.appending(
                    path: "destination-nvngx.dll.original"
                ).path
            )
        )

        let residueInspection = SteamRendererPolicyInspection(
            selection: .d3dMetalNVIDIA,
            resolvedPolicy: .d3dMetal,
            status: .error,
            userMessage: "fixture",
            appliedModules: [],
            missingModules: [],
            mixedModules: [
                "system32/nvapi.dll",
                "system32/nvapi64.dll",
                "system32/nvngx.dll"
            ]
        )
        XCTAssertTrue(
            manager.isRecoverableNVIDIAMetalFXSessionResidue(
                residueInspection,
                prefix: prefix,
                runtimeExecutable: launcher
            )
        )
        try await manager.restoreNVIDIAMetalFXRegistrySessionIfNeeded(
            prefix: prefix,
            runtimeExecutable: launcher,
            runner: runner,
            logDirectory: logDirectory
        )
        restorationFailureFileManager.arm()
        XCTAssertThrowsError(
            try manager.restoreNVIDIAMetalFXSessionModules(
                prefix: prefix,
                runtimeExecutable: launcher
            )
        )
        XCTAssertTrue(
            restorationFailureFileManager.didInjectRestorationFailure
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: moduleSessionDirectory.path)
        )
        XCTAssertEqual(
            try Data(contentsOf: stagedNVAPIAlias),
            try Data(contentsOf: sourceNVAPIAlias)
        )
        XCTAssertEqual(
            try Data(contentsOf: stagedNVAPI),
            try Data(contentsOf: sourceNVAPI)
        )
        XCTAssertEqual(
            try Data(contentsOf: stagedNGX),
            try Data(contentsOf: sourceNGX)
        )
        try manager.restoreNVIDIAMetalFXSessionModules(
            prefix: prefix,
            runtimeExecutable: launcher
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stagedNVAPIAlias.path)
        )
        XCTAssertEqual(try Data(contentsOf: stagedNVAPI), originalNVAPI)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stagedNGX.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: registryMarker.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: moduleSessionDirectory.path)
        )
        let restoredSystemRegistry = try String(
            contentsOf: prefix.appending(path: "system.reg"),
            encoding: .utf8
        )
        XCTAssertNil(
            WineUserRegistrySnapshot(contents: restoredSystemRegistry).value(
                forRegistryPath:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreRegistryPath,
                valueName:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreFullPathValueName
            )
        )
        XCTAssertNil(
            WineUserRegistrySnapshot(contents: restoredSystemRegistry).value(
                forRegistryPath:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreNativeRegistryPath,
                valueName:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreFullPathValueName
            )
        )
        XCTAssertNil(
            WineUserRegistrySnapshot(contents: restoredSystemRegistry).value(
                forRegistryPath:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXDriverRegistryPath,
                valueName:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXDriverPathValueName
            )
        )
        let registryInvocations = try String(
            contentsOf: invocationLog,
            encoding: .utf8
        ).split(separator: "\n").map(String.init)
        let expected32BitSet = [
            "reg",
            "add",
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreRegistryPath,
            "/v",
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreFullPathValueName,
            "/t",
            "REG_SZ",
            "/d",
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreSystem32Path,
            "/f",
            "/reg:32"
        ].joined(separator: " ")
        let expectedNativeSet = [
            "reg",
            "add",
            SteamRendererPolicyManager
                .nvidiaMetalFXNGXCoreNativeRegistryPath,
            "/v",
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreFullPathValueName,
            "/t",
            "REG_SZ",
            "/d",
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreSystem32Path,
            "/f",
            "/reg:64"
        ].joined(separator: " ")
        let expectedDriverPathSet = [
            "reg",
            "add",
            SteamRendererPolicyManager.nvidiaMetalFXNGXDriverRegistryPath,
            "/v",
            SteamRendererPolicyManager.nvidiaMetalFXNGXDriverPathValueName,
            "/t",
            "REG_SZ",
            "/d",
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreSystem32Path,
            "/f",
            "/reg:64"
        ].joined(separator: " ")
        let expectedStrict32BitDelete = [
            "reg",
            "delete",
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreRegistryPath,
            "/v",
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreFullPathValueName,
            "/f",
            "/reg:32"
        ].joined(separator: " ")
        let expectedStrictNativeDelete = [
            "reg",
            "delete",
            SteamRendererPolicyManager
                .nvidiaMetalFXNGXCoreNativeRegistryPath,
            "/v",
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreFullPathValueName,
            "/f",
            "/reg:64"
        ].joined(separator: " ")
        let expectedStrictDriverPathDelete = [
            "reg",
            "delete",
            SteamRendererPolicyManager.nvidiaMetalFXNGXDriverRegistryPath,
            "/v",
            SteamRendererPolicyManager.nvidiaMetalFXNGXDriverPathValueName,
            "/f",
            "/reg:64"
        ].joined(separator: " ")
        XCTAssertTrue(
            registryInvocations.contains(expected32BitSet)
        )
        XCTAssertTrue(
            registryInvocations.contains(expectedNativeSet)
        )
        XCTAssertTrue(
            registryInvocations.contains(expectedDriverPathSet)
        )
        XCTAssertTrue(
            registryInvocations.contains(expectedStrict32BitDelete)
        )
        XCTAssertTrue(
            registryInvocations.contains(expectedStrictNativeDelete)
        )
        XCTAssertTrue(
            registryInvocations.contains(expectedStrictDriverPathDelete)
        )
        XCTAssertFalse(registryInvocations.contains(where: {
            $0.hasPrefix("cmd /c ") &&
                $0.contains(
                    SteamRendererPolicyManager.nvidiaMetalFXNGXCoreRegistryPath
                )
        }))

        let legacyRegistryPath =
            "HKLM\\Software\\NVIDIA Corporation\\Global\\NGXCore"
        let legacySerializedSection = legacyRegistryPath
            .replacingOccurrences(of: "HKLM\\", with: "")
            .replacingOccurrences(of: "\\", with: "\\\\")
        try """
        WINE REGISTRY Version 2

        [\(legacySerializedSection)]
        "\(SteamRendererPolicyManager.nvidiaMetalFXNGXCoreFullPathValueName)"="C:\\\\windows\\\\system32"
        """.write(
            to: prefix.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        let legacyMarkerData = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "registryPath": legacyRegistryPath,
                "valueName": SteamRendererPolicyManager
                    .nvidiaMetalFXNGXCoreFullPathValueName,
                "stagedValue": SteamRendererPolicyManager
                    .nvidiaMetalFXNGXCoreSystem32Path
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try legacyMarkerData.write(to: registryMarker, options: .atomic)

        try await manager.stageNVIDIAMetalFXRegistrySession(
            prefix: prefix,
            runtimeExecutable: launcher,
            runner: runner,
            logDirectory: logDirectory
        )

        let migratedSystemRegistry = try String(
            contentsOf: prefix.appending(path: "system.reg"),
            encoding: .utf8
        )
        let migratedSnapshot = WineUserRegistrySnapshot(
            contents: migratedSystemRegistry
        )
        XCTAssertEqual(
            migratedSnapshot.value(
                forRegistryPath: legacyRegistryPath,
                valueName: SteamRendererPolicyManager
                    .nvidiaMetalFXNGXCoreFullPathValueName
            ),
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreSystem32Path
        )
        XCTAssertEqual(
            migratedSnapshot.value(
                forRegistryPath: SteamRendererPolicyManager
                    .nvidiaMetalFXNGXCoreRegistryPath,
                valueName: SteamRendererPolicyManager
                    .nvidiaMetalFXNGXCoreFullPathValueName
            ),
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreSystem32Path
        )
        XCTAssertEqual(
            migratedSnapshot.value(
                forRegistryPath: SteamRendererPolicyManager
                    .nvidiaMetalFXNGXDriverRegistryPath,
                valueName: SteamRendererPolicyManager
                    .nvidiaMetalFXNGXDriverPathValueName
            ),
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreSystem32Path
        )
        let migratedMarker = try JSONSerialization.jsonObject(
            with: Data(contentsOf: registryMarker)
        ) as? [String: Any]
        XCTAssertEqual(
            migratedMarker?["schemaVersion"] as? Int,
            2
        )
        let migratedProjections = migratedMarker?["projections"]
            as? [[String: Any]]
        XCTAssertEqual(migratedProjections?.count, 3)
        XCTAssertEqual(
            Set(migratedProjections?.compactMap {
                $0["registryPath"] as? String
            } ?? []),
            Set([
                SteamRendererPolicyManager
                    .nvidiaMetalFXNGXCoreNativeRegistryPath,
                SteamRendererPolicyManager.nvidiaMetalFXNGXCoreRegistryPath,
                SteamRendererPolicyManager.nvidiaMetalFXNGXDriverRegistryPath
            ])
        )

        try await manager.restoreNVIDIAMetalFXRegistrySessionIfNeeded(
            prefix: prefix,
            runtimeExecutable: launcher,
            runner: runner,
            logDirectory: logDirectory
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: registryMarker.path))
    }

    @MainActor
    func testNVIDIAMetalFXRestorationRetryRequiresBarrierAfterDeleteBecameVisible() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayMetalFXBarrierRetry-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let runtimeRoot = temporaryRoot.appending(
            path: "ForgePlayRuntime",
            directoryHint: .isDirectory
        )
        let launcher = runtimeRoot.appending(path: "wine/bin/wine")
        let renderer = runtimeRoot.appending(
            path: "Frameworks/renderer/d3dmetal",
            directoryHint: .isDirectory
        )
        let prefix = temporaryRoot.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let system32 = prefix.appending(
            path: "drive_c/windows/system32",
            directoryHint: .isDirectory
        )
        let logDirectory = temporaryRoot.appending(
            path: "Logs",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: system32,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
        try Data("fixture runtime\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        try writeD3DMetalRenderer(at: renderer)

        let registryPath = SteamRendererPolicyManager
            .nvidiaMetalFXNGXCoreRegistryPath
        let registryValueName = SteamRendererPolicyManager
            .nvidiaMetalFXNGXCoreFullPathValueName
        let registryValue = SteamRendererPolicyManager
            .nvidiaMetalFXNGXCoreSystem32Path
        let serializedSection = registryPath
            .replacingOccurrences(of: "HKLM\\", with: "")
            .replacingOccurrences(of: "\\", with: "\\\\")
        let serializedValue = registryValue.replacingOccurrences(
            of: "\\",
            with: "\\\\"
        )
        let systemRegistry = prefix.appending(path: "system.reg")
        try """
        WINE REGISTRY Version 2

        [\(serializedSection)]
        "\(registryValueName)"="\(serializedValue)"
        """.write(
            to: systemRegistry,
            atomically: true,
            encoding: .utf8
        )

        let registryMarker = prefix.appending(
            path:
                "drive_c/ForgePlay/RendererBackups/" +
                SteamRendererPolicyManager
                    .nvidiaMetalFXRegistrySessionMarkerName
        )
        try FileManager.default.createDirectory(
            at: registryMarker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let registryMarkerData = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "registryPath": registryPath,
                "valueName": registryValueName,
                "stagedValue": registryValue
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try registryMarkerData.write(to: registryMarker, options: .atomic)

        var deleteInvocationCount = 0
        var flushInvocationCount = 0
        func processResult(
            actionName: String,
            sequence: Int,
            timedOut: Bool
        ) -> ProcessRunResult {
            let stem = "\(actionName)-\(sequence)"
            var result = ProcessRunResult(
                actionName: actionName,
                executable: launcher,
                arguments: [],
                startedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
                endedAt: Date(timeIntervalSince1970: TimeInterval(sequence + 1)),
                exitCode: 0,
                stdoutLog: logDirectory.appending(path: "\(stem)-stdout.log"),
                stderrLog: logDirectory.appending(path: "\(stem)-stderr.log"),
                didTimeOut: timedOut
            )
            result.hasProcessExitCode = !timedOut
            result.forgePlayStatusCode = timedOut ? 124 : nil
            result.outcome = timedOut ? .timedOut : .exited
            result.terminationSignal = timedOut ? SIGKILL : nil
            result.rawWaitStatus = timedOut ? SIGKILL : 0
            result.processIdentifier = Int32(4_000 + sequence)
            return result
        }

        let manager = SteamRendererPolicyManager(
            registryActionExecutor: { action, _ in
                switch action {
                case .deleteRegistryValue(
                    _, let actionPrefix, let actionPath, let actionName,
                    let actionView, _
                ):
                    guard actionPrefix.standardizedFileURL ==
                            prefix.standardizedFileURL else {
                        throw NVIDIAMetalFXRegistryFixtureError.prefixMismatch
                    }
                    guard actionPath == registryPath,
                          actionName == registryValueName,
                          actionView == .bit32 else {
                        throw NVIDIAMetalFXRegistryFixtureError.unexpectedAction
                    }
                    deleteInvocationCount += 1
                    try "WINE REGISTRY Version 2\n".write(
                        to: systemRegistry,
                        atomically: true,
                        encoding: .utf8
                    )
                    return processResult(
                        actionName: "deleteRegistryValue",
                        sequence: deleteInvocationCount,
                        timedOut: false
                    )
                case .waitForWinePrefix(_, let actionPrefix, _):
                    guard actionPrefix.standardizedFileURL ==
                            prefix.standardizedFileURL else {
                        throw NVIDIAMetalFXRegistryFixtureError.prefixMismatch
                    }
                    flushInvocationCount += 1
                    return processResult(
                        actionName: "waitForWinePrefix",
                        sequence: 100 + flushInvocationCount,
                        timedOut: flushInvocationCount <= 2
                    )
                default:
                    throw NVIDIAMetalFXRegistryFixtureError.unexpectedAction
                }
            }
        )
        let runner = makeCuratedRuntimeRunner()
        XCTAssertEqual(
            try manager.stageNVIDIAMetalFXBridgeModules(
                prefix: prefix,
                runtimeExecutable: launcher
            ),
            ["nvapi.dll", "nvapi64.dll", "nvngx.dll"]
        )
        let stagedModules = ["nvapi.dll", "nvapi64.dll", "nvngx.dll"].map {
            system32.appending(path: $0)
        }
        let moduleSessionDirectory = prefix.appending(
            path:
                "drive_c/ForgePlay/RendererBackups/system32/" +
                ".forgeplay-nvidia-metalfx-session",
            directoryHint: .isDirectory
        )

        for attempt in 1...2 {
            do {
                try await manager.restoreNVIDIAMetalFXRegistrySessionIfNeeded(
                    prefix: prefix,
                    runtimeExecutable: launcher,
                    runner: runner,
                    logDirectory: logDirectory,
                    phase: .postLaunchRestoration
                )
                XCTFail("Attempt \(attempt) must retain the transaction after a timed-out barrier")
            } catch SteamLaunchError.rendererLifecycleFailed(let failure) {
                XCTAssertEqual(failure.phase, .postLaunchRestoration)
                XCTAssertEqual(failure.operation, .ngxCoreRegistryFlush)
                XCTAssertEqual(failure.processResults.count, 1)
                let processEvidence = try XCTUnwrap(
                    failure.processResults.first
                )
                XCTAssertTrue(processEvidence.didTimeOut)
                XCTAssertFalse(processEvidence.hasProcessExitCode)
                XCTAssertEqual(processEvidence.forgePlayStatusCode, 124)
                XCTAssertEqual(processEvidence.terminationSignal, SIGKILL)
                XCTAssertEqual(processEvidence.rawWaitStatus, SIGKILL)
            } catch {
                XCTFail("Unexpected restoration error: \(error)")
            }

            XCTAssertEqual(deleteInvocationCount, 1)
            XCTAssertEqual(flushInvocationCount, attempt)
            let registryAfterTimeout = try String(
                contentsOf: systemRegistry,
                encoding: .utf8
            )
            XCTAssertNil(
                WineUserRegistrySnapshot(contents: registryAfterTimeout).value(
                    forRegistryPath: registryPath,
                    valueName: registryValueName
                )
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: registryMarker.path))
            try manager.restoreNVIDIAMetalFXSessionModules(
                prefix: prefix,
                runtimeExecutable: launcher
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: moduleSessionDirectory.path))
            for stagedModule in stagedModules {
                XCTAssertTrue(FileManager.default.fileExists(atPath: stagedModule.path))
            }
        }

        try await manager.restoreNVIDIAMetalFXRegistrySessionIfNeeded(
            prefix: prefix,
            runtimeExecutable: launcher,
            runner: runner,
            logDirectory: logDirectory,
            phase: .postLaunchRestoration
        )
        XCTAssertEqual(deleteInvocationCount, 1)
        XCTAssertEqual(flushInvocationCount, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: registryMarker.path))

        try manager.restoreNVIDIAMetalFXSessionModules(
            prefix: prefix,
            runtimeExecutable: launcher
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: moduleSessionDirectory.path))
        for stagedModule in stagedModules {
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagedModule.path))
        }
    }

    func testNVIDIAMetalFXStageFailureRollsBackModulesWhileRegistryMarkerIsPresent() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayMetalFXStageRollback-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let runtimeRoot = temporaryRoot.appending(
            path: "ForgePlayRuntime",
            directoryHint: .isDirectory
        )
        let launcher = runtimeRoot.appending(path: "wine/bin/wine")
        let renderer = runtimeRoot.appending(
            path: "Frameworks/renderer/d3dmetal",
            directoryHint: .isDirectory
        )
        let prefix = temporaryRoot.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let system32 = prefix.appending(
            path: "drive_c/windows/system32",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: system32,
            withIntermediateDirectories: true
        )
        try Data("fixture runtime\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        try writeD3DMetalRenderer(at: renderer)

        let registryMarker = prefix.appending(
            path:
                "drive_c/ForgePlay/RendererBackups/" +
                SteamRendererPolicyManager
                    .nvidiaMetalFXRegistrySessionMarkerName
        )
        try FileManager.default.createDirectory(
            at: registryMarker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let markerData = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "registryPath": SteamRendererPolicyManager
                    .nvidiaMetalFXNGXCoreRegistryPath,
                "valueName": SteamRendererPolicyManager
                    .nvidiaMetalFXNGXCoreFullPathValueName,
                "stagedValue": SteamRendererPolicyManager
                    .nvidiaMetalFXNGXCoreSystem32Path
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try markerData.write(to: registryMarker, options: .atomic)

        let fileManager = RendererStageCopyFailureFileManager()
        let manager = SteamRendererPolicyManager(fileManager: fileManager)
        do {
            _ = try manager.stageNVIDIAMetalFXBridgeModules(
                prefix: prefix,
                runtimeExecutable: launcher
            )
            XCTFail("Injected staging failure must be surfaced")
        } catch SteamLaunchError.rendererBridgeInstallFailed {
            // Expected: the stage-local rollback must bypass the session
            // restoration barrier without retiring its registry marker.
        } catch {
            XCTFail("Unexpected staging error: \(error)")
        }

        XCTAssertTrue(fileManager.didInjectStageFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: registryMarker.path))
        for moduleName in ["nvapi.dll", "nvapi64.dll", "nvngx.dll"] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: system32.appending(path: moduleName).path
                )
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prefix.appending(
                    path:
                        "drive_c/ForgePlay/RendererBackups/system32/" +
                        ".forgeplay-nvidia-metalfx-session"
                ).path
            )
        )
    }

    func testNVIDIAMetalFXStagePreservesIdenticalPreexistingModule() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlayMetalFXIdentical-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let runtimeRoot = temporaryRoot.appending(
            path: "ForgePlayRuntime",
            directoryHint: .isDirectory
        )
        let launcher = runtimeRoot.appending(path: "wine/bin/wine")
        let renderer = runtimeRoot.appending(
            path: "Frameworks/renderer/d3dmetal",
            directoryHint: .isDirectory
        )
        let prefix = temporaryRoot.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let system32 = prefix.appending(
            path: "drive_c/windows/system32",
            directoryHint: .isDirectory
        )
        let syswow64 = prefix.appending(
            path: "drive_c/windows/syswow64",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: system32,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: syswow64,
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(
            to: launcher,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        try writeD3DMetalRenderer(at: renderer)
        let sourceNVAPI = renderer.appending(
            path: "wine/x86_64-windows/nvapi64.dll"
        )
        let identicalOriginal = try Data(contentsOf: sourceNVAPI)
        try identicalOriginal.write(
            to: system32.appending(path: "nvapi64.dll")
        )

        let manager = SteamRendererPolicyManager()
        _ = try manager.stageNVIDIAMetalFXBridgeModules(
            prefix: prefix,
            runtimeExecutable: launcher
        )
        let moduleSessionDirectory = prefix.appending(
            path:
                "drive_c/ForgePlay/RendererBackups/system32/" +
                ".forgeplay-nvidia-metalfx-session",
            directoryHint: .isDirectory
        )
        let destinationSnapshot = moduleSessionDirectory.appending(
            path: "destination-nvapi64.dll.original"
        )
        XCTAssertEqual(
            try Data(contentsOf: destinationSnapshot),
            identicalOriginal
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prefix.appending(
                    path:
                        "drive_c/ForgePlay/RendererBackups/system32/" +
                        "nvapi64.dll.original"
                ).path
            )
        )

        try manager.restoreNVIDIAMetalFXSessionModules(
            prefix: prefix,
            runtimeExecutable: launcher
        )
        XCTAssertEqual(
            try Data(
                contentsOf: system32.appending(path: "nvapi64.dll")
            ),
            identicalOriginal
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: moduleSessionDirectory.path)
        )
    }

    func testNVIDIAMetalFXSessionRestoresAfterRendererPayloadUpdate() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayMetalFXPayloadUpdate-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let runtimeRoot = temporaryRoot.appending(
            path: "ForgePlayRuntime",
            directoryHint: .isDirectory
        )
        let launcher = runtimeRoot.appending(path: "wine/bin/wine")
        let renderer = runtimeRoot.appending(
            path: "Frameworks/renderer/d3dmetal",
            directoryHint: .isDirectory
        )
        let prefix = temporaryRoot.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let system32 = prefix.appending(
            path: "drive_c/windows/system32",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: system32,
            withIntermediateDirectories: true
        )
        try Data("fixture runtime\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        try writeD3DMetalRenderer(at: renderer)

        let manager = SteamRendererPolicyManager()
        _ = try manager.stageNVIDIAMetalFXBridgeModules(
            prefix: prefix,
            runtimeExecutable: launcher
        )
        let stagedModules = ["nvapi.dll", "nvapi64.dll", "nvngx.dll"].map {
            system32.appending(path: $0)
        }
        let sessionDirectory = prefix.appending(
            path:
                "drive_c/ForgePlay/RendererBackups/system32/" +
                ".forgeplay-nvidia-metalfx-session",
            directoryHint: .isDirectory
        )
        let markerObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: sessionDirectory.appending(path: "session.json")
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(markerObject["schemaVersion"] as? Int, 2)
        for moduleName in ["nvapi.dll", "nvapi64.dll", "nvngx.dll"] {
            XCTAssertTrue(
                FileSystemItemPolicy.isRegularNonSymlinkFile(
                    sessionDirectory.appending(path: "staged-\(moduleName)")
                )
            )
        }

        // Simulate installing a new app/runtime version before cleanup. The
        // prior session must be identified and restored from its own immutable
        // staged snapshots, not from these newly installed payload bytes.
        for source in [
            renderer.appending(path: "wine/x86_64-windows/nvapi.dll"),
            renderer.appending(path: "wine/x86_64-windows/nvapi64.dll"),
            renderer.appending(path: "wine/x86_64-windows/nvngx-on-metalfx.dll")
        ] {
            try Data("updated \(source.lastPathComponent)\n".utf8).write(
                to: source,
                options: .atomic
            )
        }

        let residueInspection = SteamRendererPolicyInspection(
            selection: .d3dMetalNVIDIA,
            resolvedPolicy: .d3dMetal,
            status: .error,
            userMessage: "fixture",
            appliedModules: [],
            missingModules: [],
            mixedModules: [
                "system32/nvapi.dll",
                "system32/nvapi64.dll",
                "system32/nvngx.dll"
            ]
        )
        XCTAssertTrue(
            manager.isRecoverableNVIDIAMetalFXSessionResidue(
                residueInspection,
                prefix: prefix,
                runtimeExecutable: launcher
            )
        )

        try manager.restoreNVIDIAMetalFXSessionModules(
            prefix: prefix,
            runtimeExecutable: launcher
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sessionDirectory.path)
        )
        for stagedModule in stagedModules {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: stagedModule.path)
            )
        }
    }

    @MainActor
    func testSharedRendererRestoreRetiresOwnedNVIDIASessionBeforeBroadRestoreFailure() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayRendererRestoreOrder-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let runtimeRoot = temporaryRoot.appending(
            path: "ForgePlayRuntime",
            directoryHint: .isDirectory
        )
        let launcher = runtimeRoot.appending(path: "wine/bin/wine")
        let renderer = runtimeRoot.appending(
            path: "Frameworks/renderer/d3dmetal",
            directoryHint: .isDirectory
        )
        let (system32, _) = try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture runtime\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        try writeD3DMetalRenderer(at: renderer)

        let sessionDirectory = prefix.appending(
            path:
                "drive_c/ForgePlay/RendererBackups/system32/" +
                ".forgeplay-nvidia-metalfx-session",
            directoryHint: .isDirectory
        )
        let probeFileManager = RendererBroadRestoreAdmissionProbeFileManager()
        probeFileManager.transientSessionDirectory = sessionDirectory
        let policyManager = SteamRendererPolicyManager(
            fileManager: probeFileManager
        )
        _ = try policyManager.stageNVIDIAMetalFXBridgeModules(
            prefix: prefix,
            runtimeExecutable: launcher
        )

        let broadDestination = system32.appending(path: "d3d11.dll")
        let broadBackup = prefix.appending(
            path:
                "drive_c/ForgePlay/RendererBackups/system32/" +
                "d3d11.dll.original"
        )
        try FileManager.default.createDirectory(
            at: broadBackup.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("D3DMetal staged d3d11".utf8).write(
            to: broadDestination
        )
        try Data("prefix original d3d11".utf8).write(to: broadBackup)
        probeFileManager.blockedBroadBackupName =
            "d3d11.dll.original"

        let steamManager = SteamManager(
            pathManager: pathManager,
            runner: makeCuratedRuntimeRunner(),
            fileManager: probeFileManager,
            steamClientServicePreparer: { _, _, _ in }
        )
        do {
            try await steamManager.restoreSteamRendererBridgeModules(
                prefix: prefix,
                runtimeExecutable: launcher
            )
            XCTFail("Broad renderer restoration must surface the injected copy failure")
        } catch {
            // The probe deliberately fails only after transient session retirement.
        }

        XCTAssertTrue(
            probeFileManager.broadRestoreStartedAfterTransientRetirement
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sessionDirectory.path)
        )
        for moduleName in ["nvapi.dll", "nvapi64.dll", "nvngx.dll"] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: system32.appending(path: moduleName).path
                )
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: broadDestination),
            Data("D3DMetal staged d3d11".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: broadBackup),
            Data("prefix original d3d11".utf8)
        )
    }

    func testRendererRestoreRejectsSymlinkedWindowsAncestorWithoutExternalMutation() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRendererWindowsBoundary-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let prefix = temporaryRoot.appending(path: "Prefix", directoryHint: .isDirectory)
        let driveC = prefix.appending(path: "drive_c", directoryHint: .isDirectory)
        let externalWindows = temporaryRoot.appending(path: "ExternalWindows", directoryHint: .isDirectory)
        let externalSystem32 = externalWindows.appending(path: "system32", directoryHint: .isDirectory)
        let externalSysWOW64 = externalWindows.appending(path: "syswow64", directoryHint: .isDirectory)
        let destination = externalSystem32.appending(path: "d3d11.dll")
        let backup = prefix.appending(
            path: "drive_c/ForgePlay/RendererBackups/system32/d3d11.dll.original"
        )
        try FileManager.default.createDirectory(at: driveC, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalSystem32, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalSysWOW64, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: driveC.appending(path: "windows", directoryHint: .isDirectory),
            withDestinationURL: externalWindows
        )
        try Data("external renderer".utf8).write(to: destination)
        try Data("prefix original".utf8).write(to: backup)

        let manager = SteamRendererPolicyManager()
        XCTAssertThrowsError(try manager.restoreBridgeModules(
            prefix: prefix,
            runtimeExecutable: temporaryRoot.appending(path: "Runtime/wine/bin/wine")
        ))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "external renderer")
    }

    func testRendererRestoreRejectsSymlinkedBackupAncestor() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRendererBackupBoundary-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let prefix = temporaryRoot.appending(path: "Prefix", directoryHint: .isDirectory)
        let system32 = prefix.appending(path: "drive_c/windows/system32", directoryHint: .isDirectory)
        let syswow64 = prefix.appending(path: "drive_c/windows/syswow64", directoryHint: .isDirectory)
        let externalForgePlay = temporaryRoot.appending(path: "ExternalForgePlay", directoryHint: .isDirectory)
        let externalBackup = externalForgePlay.appending(
            path: "RendererBackups/system32/d3d11.dll.original"
        )
        let destination = system32.appending(path: "d3d11.dll")
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syswow64, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalBackup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: prefix.appending(path: "drive_c/ForgePlay", directoryHint: .isDirectory),
            withDestinationURL: externalForgePlay
        )
        try Data("prefix renderer".utf8).write(to: destination)
        try Data("external original".utf8).write(to: externalBackup)

        let manager = SteamRendererPolicyManager()
        XCTAssertThrowsError(try manager.restoreBridgeModules(
            prefix: prefix,
            runtimeExecutable: temporaryRoot.appending(path: "Runtime/wine/bin/wine")
        ))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "prefix renderer")
    }

    func testRendererRestoreCopyFailurePreservesExistingDestination() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRendererAtomicRestore-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let prefix = temporaryRoot.appending(path: "Prefix", directoryHint: .isDirectory)
        let system32 = prefix.appending(path: "drive_c/windows/system32", directoryHint: .isDirectory)
        let syswow64 = prefix.appending(path: "drive_c/windows/syswow64", directoryHint: .isDirectory)
        let destination = system32.appending(path: "d3d11.dll")
        let backup = prefix.appending(
            path: "drive_c/ForgePlay/RendererBackups/system32/d3d11.dll.original"
        )
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syswow64, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("current renderer".utf8).write(to: destination)
        try Data("original renderer".utf8).write(to: backup)

        let manager = SteamRendererPolicyManager(fileManager: RendererBackupCopyFailureFileManager())
        XCTAssertThrowsError(try manager.restoreBridgeModules(
            prefix: prefix,
            runtimeExecutable: temporaryRoot.appending(path: "Runtime/wine/bin/wine")
        ))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "current renderer")
    }

    func testLaunchSteamDoesNotInstallDXMTRendererIntoSteamClientSystemDirectories() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamLaunchDXMTRendererRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let (system32, syswow64) = try createSteamWindowsSystemDirectories(in: prefix)
        let runtimeRoot = temporaryRoot.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcherDirectory = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let frameworks = runtimeRoot.appending(path: "Frameworks", directoryHint: .isDirectory)
        let dxmtRenderer = frameworks.appending(path: "renderer/dxmt", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        let invocationLog = temporaryRoot.appending(path: "steam-launch-dxmt-renderer-invocations.log")

        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try writeDXMTMacDriverBridge(wineRoot: wineRoot)
        try writeDXMTRenderer(at: dxmtRenderer)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>DXMT</key>
            <true/>
            <key>D3DMETAL</key>
            <false/>
            <key>DXVK</key>
            <false/>
            <key>Program Flags</key>
            <string></string>
        </dict>
        </plist>
        """.write(to: runtimeRoot.appending(path: "Info.plist"), atomically: true, encoding: .utf8)
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try Data("original system32 d3d11".utf8).write(to: system32.appending(path: "d3d11.dll"))
        try Data("dxmt syswow64 dxgi".utf8).write(to: syswow64.appending(path: "dxgi.dll"))
        let syswow64BackupDirectory = prefix.appending(path: "drive_c/ForgePlay/RendererBackups/syswow64", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: syswow64BackupDirectory, withIntermediateDirectories: true)
        try Data("original syswow64 dxgi".utf8).write(to: syswow64BackupDirectory.appending(path: "dxgi.dll.original"))
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        printf 'WINEDLLPATH=%s\\n' "$WINEDLLPATH"
        printf 'D3DMETAL_FRAMEWORK_PATH=%s\\n' "$D3DMETAL_FRAMEWORK_PATH"
        printf 'VK_ICD_FILENAMES=%s\\n' "$VK_ICD_FILENAMES"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        try await applySteamLaunchPolicy(
            steamManager: steamManager,
            prefix: prefix,
            launcher: launcher,
            rendererPolicy: .dxmt
        )

        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .conformance,
            rendererPolicy: .dxmt
        )
        let output = try String(contentsOf: result.stdoutLog, encoding: .utf8)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.processExitCode, 0)
        XCTAssertEqual(result.forgePlayStatusCode, SteamManager.steamUIStartupFailureExitCode)
        XCTAssertNotNil(result.diagnosticLog)
        XCTAssertEqual(
            try String(contentsOf: system32.appending(path: "d3d11.dll"), encoding: .utf8),
            "original system32 d3d11"
        )
        XCTAssertEqual(
            try String(contentsOf: syswow64.appending(path: "dxgi.dll"), encoding: .utf8),
            "original syswow64 dxgi"
        )
        XCTAssertTrue(output.contains("WINEDLLPATH="), output)
        XCTAssertFalse(output.contains("renderer/dxmt"), output)
        XCTAssertFalse(output.contains("D3DMETAL_FRAMEWORK_PATH=D3DMetal.framework"), output)
        XCTAssertFalse(output.contains("D3DMetal.framework"), output)
        XCTAssertTrue(output.contains("VK_ICD_FILENAMES="), output)
        XCTAssertFalse(output.contains("VK_ICD_FILENAMES=/dev/null"), output)
        let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
        XCTAssertTrue(invocations.contains("C:\\Program Files (x86)\\Steam\\steam.exe"), invocations)
        XCTAssertFalse(invocations.contains("-cef-disable-gpu"), invocations)
        XCTAssertFalse(invocations.contains("-cef-disable-gpu-compositing"), invocations)
        XCTAssertFalse(invocations.contains("launch-steam.bat"), invocations)
        XCTAssertFalse(invocations.contains("-cef-force-32bit"), invocations)
        XCTAssertTrue(invocations.contains("-no-cef-sandbox"), invocations)
    }

    func testSteamPrefixServiceRepairsMixedRendererPolicyAndReinspectPasses() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamRendererRepairRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        let runner = makeCuratedRuntimeRunner()
        let lifecycleCoordinator = SteamPrefixLifecycleCoordinator()
        let prefixManager = PrefixManager(
            pathManager: pathManager,
            runner: runner,
            lifecycleCoordinator: lifecycleCoordinator
        )
        let steamManager = SteamManager(pathManager: pathManager, runner: runner)
        try pathManager.configureRoot(temporaryRoot)
        _ = try prefixManager.createSteamSharedPrefix()
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let (system32, syswow64) = try createSteamWindowsSystemDirectories(in: prefix)
        let steamDirectory = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try FileManager.default.createDirectory(
            at: prefix.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win64\n".write(
            to: prefix.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefix.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
        let runnerRoot = temporaryRoot.appending(path: "ForgePlayRuntime", directoryHint: .isDirectory)
        let launcherDirectory = runnerRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let wineRoot = runnerRoot.appending(path: "wine", directoryHint: .isDirectory)
        let d3dMetalRenderer = runnerRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let dxvkRenderer = runnerRoot.appending(path: "Frameworks/renderer/dxvk", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try writeD3DMetalRenderer(at: d3dMetalRenderer)
        try writeRendererWith64And32BitWindowsModules(
            at: dxvkRenderer,
            externalFrameworkName: nil,
            modulePayloads64: [
                "d3d9.dll": "dxvk64 d3d9",
                "d3d11.dll": "dxvk64 d3d11",
                "dxgi.dll": "dxvk64 dxgi"
            ],
            modulePayloads32: [
                "d3d9.dll": "dxvk32 d3d9",
                "d3d11.dll": "dxvk32 d3d11",
                "dxgi.dll": "dxvk32 dxgi"
            ]
        )
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "$WINEPREFIX/policy-action-invocations.log"
        \(steamRegistryRecordingShellPreamble())
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let windowsRuntimeService = WindowsRuntimeService(
            pathManager: pathManager,
            runner: runner,
            bundledRuntimeExecutableProvider: { launcher },
            lifecycleCoordinator: lifecycleCoordinator
        )
        let steamPrefixService = SteamPrefixService(
            windowsRuntimeService: windowsRuntimeService,
            prefixManager: prefixManager,
            steamManager: steamManager,
            lifecycleCoordinator: lifecycleCoordinator
        )

        let runtimePreparation = try await prefixManager.prepareSteamSharedPrefix(
            runtimeExecutable: launcher
        )
        XCTAssertNotNil(runtimePreparation.metadata.runtimeBinding)
        XCTAssertEqual(
            try String(
                contentsOf: prefix.appending(path: ".update-timestamp"),
                encoding: .utf8
            ),
            "disable\n"
        )
        try FileManager.default.removeItem(
            at: prefix.appending(path: "policy-action-invocations.log")
        )

        try Data("dxvk64 d3d9".utf8).write(to: system32.appending(path: "d3d9.dll"))
        try Data("dxvk64 d3d11".utf8).write(to: system32.appending(path: "d3d11.dll"))
        try Data("dxvk64 dxgi".utf8).write(to: system32.appending(path: "dxgi.dll"))
        try Data("dxvk32 d3d9".utf8).write(to: syswow64.appending(path: "d3d9.dll"))
        try Data("dxvk32 d3d11".utf8).write(to: syswow64.appending(path: "d3d11.dll"))
        try Data("dxvk32 dxgi".utf8).write(to: syswow64.appending(path: "dxgi.dll"))
        let system32Backup = prefix.appending(path: "drive_c/ForgePlay/RendererBackups/system32", directoryHint: .isDirectory)
        let syswow64Backup = prefix.appending(path: "drive_c/ForgePlay/RendererBackups/syswow64", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: system32Backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syswow64Backup, withIntermediateDirectories: true)
        try Data("original64 d3d9".utf8).write(to: system32Backup.appending(path: "d3d9.dll.original"))
        try Data("original32 d3d9".utf8).write(to: syswow64Backup.appending(path: "d3d9.dll.original"))

        let contaminated = steamManager.inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: launcher,
            selection: .d3dMetal
        )
        XCTAssertEqual(contaminated.status, .error)
        XCTAssertTrue(contaminated.requiresRepair)
        XCTAssertTrue(contaminated.mixedModules.contains("system32/d3d9.dll"), contaminated.mixedModules.joined(separator: "\n"))
        XCTAssertTrue(contaminated.mixedModules.contains("system32/d3d11.dll"), contaminated.mixedModules.joined(separator: "\n"))
        XCTAssertTrue(contaminated.mixedModules.contains("system32/dxgi.dll"), contaminated.mixedModules.joined(separator: "\n"))
        XCTAssertTrue(contaminated.mixedModules.contains("syswow64/d3d9.dll"), contaminated.mixedModules.joined(separator: "\n"))
        XCTAssertTrue(contaminated.mixedModules.contains("syswow64/d3d11.dll"), contaminated.mixedModules.joined(separator: "\n"))
        XCTAssertTrue(contaminated.mixedModules.contains("syswow64/dxgi.dll"), contaminated.mixedModules.joined(separator: "\n"))

        let repaired = try await steamPrefixService.applyRendererPolicy(
            prefix: prefix,
            runtimeExecutable: launcher,
            selection: .d3dMetal,
            videoMemorySelection: .gb8
        )
        XCTAssertEqual(repaired.status, .ok)
        XCTAssertFalse(repaired.requiresRepair)
        XCTAssertFalse(repaired.requiresApply)
        XCTAssertTrue(repaired.appliedModules.isEmpty, repaired.appliedModules.joined(separator: "\n"))
        XCTAssertTrue(repaired.missingProfileOverrides.isEmpty)
        XCTAssertTrue(repaired.staleProfileOverrides.isEmpty, repaired.staleProfileOverrides.joined(separator: "\n"))
        XCTAssertTrue(
            repaired.appliedProfileOverrides.contains(
                "HKCU\\Software\\Wine\\Direct3D\\VideoMemorySize=8192"
            ),
            repaired.appliedProfileOverrides.joined(separator: "\n")
        )
        let policyActionInvocations = try String(
            contentsOf: prefix.appending(path: "policy-action-invocations.log"),
            encoding: .utf8
        ).split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertFalse(
            policyActionInvocations.contains { $0.contains("-shutdown") },
            "Prefix policy repair must not start steam.exe solely to request shutdown"
        )
        let wineServerShutdownIndex = try XCTUnwrap(
            policyActionInvocations.firstIndex { $0.contains("wineserver --kill=\(SIGTERM)") }
        )
        let firstRegistryMutationIndex = try XCTUnwrap(
            policyActionInvocations.firstIndex { $0.contains("reg add") }
        )
        XCTAssertLessThan(wineServerShutdownIndex, firstRegistryMutationIndex)

        XCTAssertEqual(try String(contentsOf: system32.appending(path: "d3d9.dll"), encoding: .utf8), "original64 d3d9")
        XCTAssertFalse(FileManager.default.fileExists(atPath: system32.appending(path: "d3d11.dll").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: system32.appending(path: "dxgi.dll").path))
        XCTAssertEqual(try String(contentsOf: syswow64.appending(path: "d3d9.dll"), encoding: .utf8), "original32 d3d9")
        XCTAssertFalse(FileManager.default.fileExists(atPath: syswow64.appending(path: "d3d11.dll").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: syswow64.appending(path: "dxgi.dll").path))

        let reinspected = steamManager.inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: launcher,
            selection: .d3dMetal,
            videoMemorySizeMB: 8_192
        )
        XCTAssertEqual(reinspected.status, .ok)
        XCTAssertFalse(reinspected.requiresRepair)
        XCTAssertFalse(reinspected.requiresApply)
        XCTAssertTrue(reinspected.mixedModules.isEmpty)
        XCTAssertTrue(reinspected.missingModules.isEmpty)
        XCTAssertTrue(reinspected.missingProfileOverrides.isEmpty)
    }

    func testSteamRendererPolicyInspectionRequiresSteamClientProfileOverrides() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamRendererProfileRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let services = AppServices()
        try services.pathManager.configureRoot(temporaryRoot)
        let prefix = try services.steamSharedPrefixURL()
        _ = try createSteamWindowsSystemDirectories(in: prefix)
        let runnerRoot = temporaryRoot.appending(path: "ForgePlayRuntime", directoryHint: .isDirectory)
        let launcherDirectory = runnerRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let wineRoot = runnerRoot.appending(path: "wine", directoryHint: .isDirectory)
        let d3dMetalRenderer = runnerRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try writeD3DMetalRenderer(at: d3dMetalRenderer)
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let missingProfile = services.steamManager.inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: launcher,
            selection: .d3dMetal
        )
        XCTAssertEqual(missingProfile.status, .warning)
        XCTAssertFalse(missingProfile.requiresRepair)
        XCTAssertTrue(missingProfile.requiresApply)
        XCTAssertTrue(missingProfile.missingModules.isEmpty)
        XCTAssertFalse(missingProfile.missingProfileOverrides.isEmpty)
        XCTAssertTrue(
            missingProfile.missingProfileOverrides.contains {
                $0.contains("gameoverlayrenderer=<empty>")
            },
            missingProfile.missingProfileOverrides.joined(separator: "\n")
        )

        let userRegistryContents = SteamClientCompatibilityProfileContract.requiredRegistryOverrides
            .map { requirement in
                """
                [\(requirement.registryPath)]
                "\(requirement.valueName)"="\(requirement.expectedValue)"
                """
            }
            .joined(separator: "\n")
        try userRegistryContents.write(
            to: prefix.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
        let systemRegistryContents = SteamClientCompatibilityProfileContract.requiredSystemRegistryOverrides
            .map { requirement in
                let valueLine = requirement.valueType == "REG_DWORD"
                    ? "\"\(requirement.valueName)\"=\(requirement.expectedValue)"
                    : "\"\(requirement.valueName)\"=\"\(requirement.expectedValue)\""
                return """
                [\(requirement.registryPath)]
                \(valueLine)
                """
            }
            .joined(separator: "\n")
        try systemRegistryContents.write(
            to: prefix.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )

        let satisfiedProfile = services.steamManager.inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: launcher,
            selection: .d3dMetal
        )
        XCTAssertEqual(satisfiedProfile.status, .ok)
        XCTAssertFalse(satisfiedProfile.requiresApply)
        XCTAssertTrue(satisfiedProfile.missingProfileOverrides.isEmpty)
        XCTAssertFalse(satisfiedProfile.appliedProfileOverrides.isEmpty)
        XCTAssertTrue(satisfiedProfile.staleProfileOverrides.isEmpty)

        let realWineSystemRegistryContents = SteamClientCompatibilityProfileContract.requiredSystemRegistryOverrides
            .map { requirement in
                let registryPath = requirement.registryPath.replacingOccurrences(
                    of: "HKLM\\System\\CurrentControlSet\\",
                    with: "HKLM\\System\\ControlSet001\\"
                )
                let valueLine = requirement.valueType == "REG_DWORD"
                    ? "\"\(requirement.valueName)\"=\(requirement.expectedValue)"
                    : "\"\(requirement.valueName)\"=\"\(requirement.expectedValue)\""
                return """
                [\(registryPath)]
                \(valueLine)
                """
            }
            .joined(separator: "\n")
        try realWineSystemRegistryContents.write(
            to: prefix.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        let satisfiedRealWineProfile = services.steamManager.inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: launcher,
            selection: .d3dMetal
        )
        XCTAssertEqual(satisfiedRealWineProfile.status, .ok)
        XCTAssertFalse(satisfiedRealWineProfile.requiresApply)
        XCTAssertTrue(satisfiedRealWineProfile.missingProfileOverrides.isEmpty)

        let steamBin = prefix.appending(path: "drive_c/Program Files (x86)/Steam/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamBin, withIntermediateDirectories: true)
        try Data("driver-query".utf8).write(to: steamBin.appending(path: "gldriverquery.exe"))
        try Data("stale-sdl2".utf8).write(to: steamBin.appending(path: "SDL2.dll"))
        try Data("stale-sdl3".utf8).write(to: steamBin.appending(path: "SDL3.dll"))
        let staleClientFiles = services.steamManager.inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: launcher,
            selection: .d3dMetal
        )
        XCTAssertEqual(staleClientFiles.status, .error)
        XCTAssertTrue(staleClientFiles.requiresRepair)
        XCTAssertFalse(staleClientFiles.requiresApply)
        XCTAssertFalse(staleClientFiles.staleSteamClientFiles.isEmpty)
        XCTAssertFalse(staleClientFiles.userMessage.localizedCaseInsensitiveContains("SDL"))
        XCTAssertFalse(staleClientFiles.userMessage.localizedCaseInsensitiveContains("gldriverquery"))
    }

    func testSteamClientProfileWineBusRequirementsEnableMacOSIOHID() {
        let wineBusRequirements = SteamClientCompatibilityProfileContract.requiredSystemRegistryOverrides
            .filter { $0.registryPath == "HKLM\\System\\CurrentControlSet\\Services\\winebus" }
        let requirementsByName = Dictionary(
            uniqueKeysWithValues: wineBusRequirements.map { ($0.valueName, $0) }
        )

        XCTAssertEqual(
            Set(requirementsByName.keys),
            ["DisableHidraw", "DisableInput", "Enable SDL", "Map Controllers"]
        )
        for requirement in requirementsByName.values {
            XCTAssertEqual(requirement.valueType, "REG_DWORD")
            XCTAssertEqual(requirement.valueData, "0")
            XCTAssertEqual(requirement.expectedValue, "dword:00000000")
        }
    }

    func testSteamClientProfileMigratesWineBusToMacOSIOHIDAndRemovesRendererIsolationOverrides() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamClientProfileRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let services = AppServices()
        try services.pathManager.configureRoot(temporaryRoot)
        let prefix = try services.steamSharedPrefixURL()
        let launcher = temporaryRoot.appending(path: "wine")
        let launchLogs = temporaryRoot.appending(path: "LaunchLogs", directoryHint: .isDirectory)
        let invocationLog = temporaryRoot.appending(path: "steam-client-profile-invocations.log")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchLogs, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        \(steamRegistryRecordingShellPreamble())
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try """
        [Software\\\\Wine\\\\DllOverrides]
        "gameoverlayrenderer"=""

        [Software\\\\Wine\\\\AppDefaults\\\\steam.exe\\\\DllOverrides]
        "d3d11"="builtin"
        "dxgi"="builtin"

        [Software\\\\Wine\\\\AppDefaults\\\\steamwebhelper.exe\\\\DllOverrides]
        "libglesv2"="native,builtin"
        "d3d9"="builtin"
        """.write(to: prefix.appending(path: "user.reg"), atomically: true, encoding: .utf8)
        try """
        [System\\ControlSet001\\Services\\winebus]
        "DisableHidraw"=dword:00000001
        "DisableInput"=dword:00000001
        "Enable SDL"=dword:00000001
        "Map Controllers"=dword:00000001
        """.write(to: prefix.appending(path: "system.reg"), atomically: true, encoding: .utf8)

        let contaminatedProfile = SteamClientCompatibilityProfileContract.inspect(prefix: prefix)
        XCTAssertFalse(contaminatedProfile.isSatisfied)
        XCTAssertFalse(contaminatedProfile.staleOverrides.isEmpty)
        for valueName in ["DisableHidraw", "DisableInput", "Enable SDL", "Map Controllers"] {
            XCTAssertTrue(
                contaminatedProfile.missingOverrides.contains {
                    $0.contains("winebus\\\(valueName)=dword:00000000")
                },
                contaminatedProfile.missingOverrides.joined(separator: "\n")
            )
        }
        XCTAssertTrue(
            contaminatedProfile.staleOverrides.contains {
                $0.contains("steam.exe") && $0.contains("d3d11=<removed>")
            },
            contaminatedProfile.staleOverrides.joined(separator: "\n")
        )
        XCTAssertTrue(
            contaminatedProfile.staleOverrides.contains {
                $0.contains("steamwebhelper.exe") && $0.contains("libglesv2=<removed>")
            },
            contaminatedProfile.staleOverrides.joined(separator: "\n")
        )

        let steamClientProfile = SteamClientCompatibilityProfile(runner: makeCuratedRuntimeRunner())
        let firstApplyFailure = try await steamClientProfile.apply(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: launchLogs
        )
        XCTAssertNil(firstApplyFailure)

        let cleanedProfile = SteamClientCompatibilityProfileContract.inspect(prefix: prefix)
        let invocations = (try? String(contentsOf: invocationLog, encoding: .utf8)) ?? "<missing invocation log>"
        XCTAssertTrue(
            invocations.split(whereSeparator: \.isNewline).contains("wineserver -w"),
            "Registry profile changes must wait for a natural wineserver exit so they are persisted.\n\(invocations)"
        )
        XCTAssertFalse(invocations.contains("--kill="), invocations)
        XCTAssertTrue(
            cleanedProfile.isSatisfied,
            "\(cleanedProfile.missingOverrides.joined(separator: "\n"))\n\(invocations)"
        )
        XCTAssertTrue(cleanedProfile.appliedOverrides.contains { $0.contains("gameoverlayrenderer=<empty>") })
        XCTAssertTrue(cleanedProfile.appliedOverrides.contains { $0.contains("Mac Driver\\UsePreciseScrolling=N") })
        XCTAssertTrue(cleanedProfile.appliedOverrides.contains { $0.contains("*vulkandriverquery.exe=<empty>") })
        XCTAssertTrue(cleanedProfile.appliedOverrides.contains { $0.contains("*vulkandriverquery64.exe=<empty>") })
        XCTAssertTrue(cleanedProfile.appliedOverrides.contains { $0.contains("AeDebug\\Debugger=false") })
        for valueName in ["DisableHidraw", "DisableInput", "Enable SDL", "Map Controllers"] {
            XCTAssertTrue(
                cleanedProfile.appliedOverrides.contains {
                    $0.contains("winebus\\\(valueName)=dword:00000000")
                },
                cleanedProfile.appliedOverrides.joined(separator: "\n")
            )
            XCTAssertTrue(
                invocations.split(whereSeparator: \.isNewline).contains {
                    $0.contains(valueName) && $0.contains("/d 0")
                },
                invocations
            )
        }
        XCTAssertTrue(cleanedProfile.missingOverrides.isEmpty, cleanedProfile.missingOverrides.joined(separator: "\n"))
        XCTAssertTrue(cleanedProfile.staleOverrides.isEmpty)

        let invocationTextAfterRepair = try String(contentsOf: invocationLog, encoding: .utf8)
        XCTAssertFalse(
            invocationTextAfterRepair.contains("AppDefaults\\\\steam.exe\\\\DllOverrides") &&
                invocationTextAfterRepair.contains("d3d8"),
            "Profile repair must not issue delete commands for overrides that were never present"
        )

        let secondApplyFailure = try await steamClientProfile.apply(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: launchLogs
        )
        XCTAssertNil(secondApplyFailure)

        XCTAssertEqual(
            try String(contentsOf: invocationLog, encoding: .utf8),
            invocationTextAfterRepair,
            "A satisfied Steam compatibility profile must not launch Wine or flush the prefix again"
        )
    }

    func testSteamClientProfileAppliesSDL3BackedSDL2CompatForDriverQuery() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamSDLCompatRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        try createSteamWindowsSystemDirectories(in: prefix)
        let steamBin = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/bin",
            directoryHint: .isDirectory
        )
        let steamCEF = steamBin.appending(path: "cef/cef.win64", directoryHint: .isDirectory)
        let launcher = temporaryRoot.appending(path: "wine")
        try FileManager.default.createDirectory(at: steamBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamCEF, withIntermediateDirectories: true)
        try Data("steam gpu query fixture".utf8).write(to: steamBin.appending(path: "gldriverquery.exe"))
        try Data("steam webhelper fixture".utf8).write(to: steamCEF.appending(path: "steamwebhelper.exe"))
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let missingProfile = SteamClientCompatibilityProfileContract.inspect(prefix: prefix)
        XCTAssertTrue(missingProfile.webHelperFiles.isSatisfied)
        XCTAssertFalse(missingProfile.driverQueryCompatibilityFiles.isSatisfied)
        XCTAssertTrue(
            missingProfile.driverQueryCompatibilityFiles.missing.contains {
                $0.contains("Steam/bin/SDL2.dll") && $0.contains("sdl2-compat")
            },
            missingProfile.driverQueryCompatibilityFiles.missing.joined(separator: "\n")
        )
        XCTAssertTrue(
            missingProfile.driverQueryCompatibilityFiles.missing.contains {
                $0.contains("Steam/bin/SDL3.dll") && $0.contains("sdl2-compat")
            },
            missingProfile.driverQueryCompatibilityFiles.missing.joined(separator: "\n")
        )
        XCTAssertTrue(
            missingProfile.webHelperFiles.applied.contains {
                $0.contains("Steam/bin/cef/cef.win64/steamwebhelper.exe") &&
                    $0.contains("valve-managed")
            },
            missingProfile.webHelperFiles.applied.joined(separator: "\n")
        )

        _ = try await steamManager.applySteamClientCompatibilityProfile(
            runtimeExecutable: launcher,
            prefix: prefix
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fontV13MarkerURL(prefix).path
            ),
            "Steam client registry/file preparation must not run the final font convergence barrier"
        )

        let resourceDirectory = try XCTUnwrap(
            SteamClientCompatibilityProfileContract.sdl2CompatResourceDirectory()
        )
        for fileName in ["SDL2.dll", "SDL3.dll"] {
            let source = resourceDirectory.appending(path: fileName)
            let destination = steamBin.appending(path: fileName)
            XCTAssertTrue(
                FileManager.default.contentsEqual(atPath: source.path, andPath: destination.path),
                "\(fileName) should be the bundled SDL3-backed sdl2-compat file"
            )
        }
        let webHelper = steamCEF.appending(path: "steamwebhelper.exe")
        let preservedWebHelper = steamCEF.appending(
            path: "steamwebhelper.forgeplay-original.exe"
        )
        XCTAssertEqual(
            try Data(contentsOf: webHelper),
            Data("steam webhelper fixture".utf8),
            "ForgePlay must leave Valve's active Steam WebHelper unchanged"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: preservedWebHelper.path),
            "The runtime process policy does not require a duplicate Steam WebHelper backup"
        )

        let appliedProfile = SteamClientCompatibilityProfileContract.inspect(prefix: prefix)
        XCTAssertTrue(appliedProfile.isSatisfied)
        XCTAssertTrue(appliedProfile.webHelperFiles.isSatisfied)
        XCTAssertTrue(appliedProfile.driverQueryCompatibilityFiles.isSatisfied)
        XCTAssertTrue(appliedProfile.missingFiles.isEmpty)
        XCTAssertTrue(appliedProfile.staleFiles.isEmpty)
        XCTAssertTrue(
            appliedProfile.appliedFiles.contains {
                $0.contains("Steam/bin/SDL2.dll") && $0.contains("sdl2-compat")
            },
            appliedProfile.appliedFiles.joined(separator: "\n")
        )
        XCTAssertTrue(
            appliedProfile.appliedFiles.contains {
                $0.contains("Steam/bin/SDL3.dll") && $0.contains("sdl2-compat")
            },
            appliedProfile.appliedFiles.joined(separator: "\n")
        )
        XCTAssertTrue(
            appliedProfile.appliedFiles.contains {
                $0.contains("Steam/bin/cef/cef.win64/steamwebhelper.exe") &&
                    $0.contains("valve-managed")
            },
            appliedProfile.appliedFiles.joined(separator: "\n")
        )
    }

    func testSteamClientProfileRestoresLegacyWebHelperOriginalBackup() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamWebHelperShimRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        try createSteamWindowsSystemDirectories(in: prefix)
        let steamCEF = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/bin/cef/cef.win7x64",
            directoryHint: .isDirectory
        )
        let launcher = temporaryRoot.appending(path: "wine")
        try FileManager.default.createDirectory(at: steamCEF, withIntermediateDirectories: true)
        try Data("obsolete steamwebhelper-shim.c fixture".utf8).write(
            to: steamCEF.appending(path: "steamwebhelper.exe")
        )
        try FileManager.default.createDirectory(
            at: steamCEF.appending(path: "forgeplay-original", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("legacy original webhelper".utf8).write(
            to: steamCEF.appending(path: "forgeplay-original/steamwebhelper.exe")
        )
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let staleProfile = SteamClientCompatibilityProfileContract.inspect(prefix: prefix)
        XCTAssertFalse(staleProfile.isSatisfied)
        XCTAssertFalse(staleProfile.webHelperFiles.isSatisfied)
        XCTAssertTrue(staleProfile.driverQueryCompatibilityFiles.isSatisfied)
        XCTAssertTrue(
            staleProfile.webHelperFiles.stale.contains {
                $0.contains("forgeplay-original/steamwebhelper.exe") &&
                    $0.contains("legacy-original-location")
            },
            staleProfile.webHelperFiles.stale.joined(separator: "\n")
        )

        _ = try await steamManager.applySteamClientCompatibilityProfile(
            runtimeExecutable: launcher,
            prefix: prefix
        )

        XCTAssertEqual(
            try Data(contentsOf: steamCEF.appending(path: "steamwebhelper.exe")),
            Data("legacy original webhelper".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: steamCEF.appending(path: "steamwebhelper.forgeplay-original.exe").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: steamCEF.appending(path: "forgeplay-original/steamwebhelper.exe").path
            )
        )
        let appliedProfile = SteamClientCompatibilityProfileContract.inspect(prefix: prefix)
        XCTAssertTrue(appliedProfile.isSatisfied, appliedProfile.staleFiles.joined(separator: "\n"))
    }

    func testSteamClientProfileRemovesObsoleteBootstrapUpdatePin() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamBootstrapRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        try createSteamWindowsSystemDirectories(in: prefix)
        let steamDirectory = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        let launcher = temporaryRoot.appending(path: "wine")
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try Data("steam bootstrapper fixture".utf8).write(to: steamDirectory.appending(path: "Steam.exe"))
        try SteamClientCompatibilityProfileContract.obsoleteSteamBootstrapPinContents.write(
            to: steamDirectory.appending(path: "steam.cfg"),
            atomically: true,
            encoding: .utf8
        )
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        _ = try await steamManager.applySteamClientCompatibilityProfile(
            runtimeExecutable: launcher,
            prefix: prefix
        )

        let steamConfig = steamDirectory.appending(path: "steam.cfg")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: steamConfig.path),
            "ForgePlay must remove its obsolete Steam self-update suppression file"
        )
        let appliedProfile = SteamClientCompatibilityProfileContract.inspect(prefix: prefix)
        XCTAssertTrue(appliedProfile.missingFiles.isEmpty)
        XCTAssertTrue(appliedProfile.staleFiles.isEmpty)
    }

    func testOperationalLaunchDefersEvidenceGateAndKeepsSteamRunningDuringBootstrapUpdate() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamBootstrapUpdateLaunchRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        var snapshotCallCount = 0
        let steamManager = makeSteamManager(
            pathManager: pathManager,
            processSnapshotProvider: {
                snapshotCallCount += 1
                guard snapshotCallCount >= 3 else {
                    return SteamLaunchProcessSnapshot(processes: [])
                }
                return SteamLaunchProcessSnapshot(processes: [
                    SteamLaunchObservedProcess(
                        processID: 50_025,
                        command: "wine C:\\Program Files (x86)\\Steam\\steam.exe WINEPREFIX=\(prefix.path)",
                        processStartedAtUnixMicroseconds: 960_001
                    ),
                    SteamLaunchObservedProcess(
                        processID: 50_026,
                        command: "/Users/test/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/ipcserver"
                    )
                ])
            },
            managedWineLaunchProcessIdentityProvider: { _, _ in
                [
                    ManagedWineLaunchProcessIdentity(
                        processID: 50_025,
                        processStartedAtUnixMicroseconds: 960_001,
                        executableURL: temporaryRoot.appending(
                            path: "BundledResources/Runners/ForgePlayRuntime/wine/bin/wine.bin"
                        )
                    )
                ]
            },
            managedWineJournalProcessSnapshotProvider: { identities in
                guard snapshotCallCount >= 2,
                      let identity = identities.first else {
                    return SteamLaunchProcessSnapshot(processes: [])
                }
                return SteamLaunchProcessSnapshot(processes: [
                    SteamLaunchObservedProcess(
                        processID: identity.processID,
                        command:
                            "wine C:\\Program Files (x86)\\Steam\\steam.exe WINEPREFIX=\(prefix.path)",
                        evidenceSource: .managedWineJournal,
                        processStartedAtUnixMicroseconds:
                            identity.processStartedAtUnixMicroseconds
                    )
                ])
            }
        )
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let runtimeRoot = temporaryRoot.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcherDirectory = runtimeRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        if [ "$1" = "--version" ]; then
          printf 'wine-11.12\\n'
          exit 0
        fi
        if [ "$1" = "cmd" ] && [ "$2" = "/c" ]; then
          printf 'Microsoft Windows 10.0.19045\\n'
          exit 0
        fi
        if [ "$1" = "wineserver" ]; then
          exit 0
        fi
        log_dir="$WINEPREFIX/drive_c/Program Files (x86)/Steam/logs"
        mkdir -p "$log_dir"
        printf '[2026-07-06 17:37:45] Startup - updater built May 20 2024\\r\\n'
        printf '[2026-07-06 17:37:45] Steam Client launched with: "C:\\\\Program Files (x86)\\\\Steam\\\\steam.exe" "-no-cef-sandbox"\\r\\n'
        printf '[2026-07-06 17:38:48] 업데이트 다운로드 중...(332,874/336,229KB)\\r\\n' > "$log_dir/bootstrap_log.txt"
        sleep 12
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try await applySteamLaunchPolicy(steamManager: steamManager, prefix: prefix, launcher: launcher)

        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .operational,
            rendererPolicy: .d3dMetal
        )
        let diagnosticLog = try XCTUnwrap(result.diagnosticLog)
        let diagnostics = try String(contentsOf: diagnosticLog, encoding: .utf8)

        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.waitedForExit)
        XCTAssertNil(result.processExitCode)
        XCTAssertEqual(result.forgePlayStatusCode, SteamManager.steamBootstrapUpdateInProgressExitCode)
        XCTAssertEqual(SteamUIVerificationState.inferred(from: result), .launchedButUnverified)
        XCTAssertTrue(diagnostics.contains("Status: DEFERRED"), diagnostics)
        XCTAssertTrue(diagnostics.contains("steam-bootstrap-update-in-progress"), diagnostics)
        XCTAssertTrue(diagnostics.contains("Steam bootstrap update was still in progress"), diagnostics)
        XCTAssertTrue(
            diagnostics.contains("Host macOS Steam process evidence (allowed for operational launch):"),
            diagnostics
        )
        XCTAssertTrue(diagnostics.contains("did not stop Windows Steam; UI verification is deferred"), diagnostics)
        XCTAssertFalse(diagnostics.contains("Post-failure Steam Prefix process shutdown:"), diagnostics)
    }

    func testOperationalLaunchDefersWithoutCleanupWhenProcessEvidenceIsUnavailable() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayOperationalSteamLaunchRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(
            pathManager: pathManager,
            processEvidenceTimeout: 0.2,
            processEvidencePollInterval: 0.1
        )
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let runtimeRoot = temporaryRoot.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcherDirectory = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        let invocationLog = temporaryRoot.appending(path: "operational-steam-launch-invocations.log")

        try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        if [ "$1" = "--version" ]; then
          printf 'wine-11.12\\n'
          exit 0
        fi
        if [ "$1" = "wineserver" ]; then
          exit 0
        fi
        if [ "$2" = "-shutdown" ]; then
          exit 0
        fi
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try await applySteamLaunchPolicy(steamManager: steamManager, prefix: prefix, launcher: launcher)
        try? FileManager.default.removeItem(at: invocationLog)

        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .operational,
            rendererPolicy: .d3dMetal
        )
        let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.processExitCode, 0)
        XCTAssertEqual(result.forgePlayStatusCode, SteamManager.steamLaunchProcessVerificationUnavailableExitCode)
        XCTAssertEqual(SteamUIVerificationState.inferred(from: result), .launchedButUnverified)
        XCTAssertNotNil(result.diagnosticLog)
        let diagnostics = try String(contentsOf: try XCTUnwrap(result.diagnosticLog), encoding: .utf8)
        XCTAssertTrue(diagnostics.contains("Status: DEFERRED"), diagnostics)
        XCTAssertTrue(diagnostics.contains("operational-process-evidence-unavailable"), diagnostics)
        XCTAssertTrue(diagnostics.contains("bounded process-evidence deadline"), diagnostics)
        XCTAssertTrue(diagnostics.contains("did not stop Steam; confirm the visible window directly"), diagnostics)
        XCTAssertFalse(diagnostics.contains("Post-failure Steam Prefix process shutdown:"), diagnostics)
        let evidence = try ProcessRunEvidenceWriter.read(
            from: try XCTUnwrap(result.runEvidenceLog)
        )
        XCTAssertEqual(evidence.forgePlayStatusCode, result.forgePlayStatusCode)
        XCTAssertEqual(evidence.diagnosticLog, result.diagnosticLog?.standardizedFileURL.path)
        XCTAssertEqual(
            Set(evidence.relatedRunEvidenceLogs ?? []),
            Set(result.relatedRunEvidenceLogs.map(\.standardizedFileURL.path))
        )
        XCTAssertNotNil(evidence.finalizedAt)
        let steamLaunchIndex = try XCTUnwrap(
            invocations.lastIndex {
                $0.contains("C:\\Program Files (x86)\\Steam\\steam.exe") && !$0.contains("-shutdown")
            }
        )
        XCTAssertFalse(
            invocations.dropFirst(steamLaunchIndex + 1).contains("wineserver --kill=\(SIGTERM)"),
            invocations.joined(separator: "\n")
        )
    }

    func testSteamUIFailureOutranksDeferredVerificationEvidence() {
        XCTAssertTrue(SteamManager.shouldDeferSteamUIVerification(
            bootstrapUpdateInProgress: false,
            operationalProcessVerificationUnavailable: true,
            didObserveExternalRunnerDuringConformance: false,
            hasTerminalSteamUIFailure: false
        ))
        XCTAssertTrue(SteamManager.shouldDeferSteamUIVerification(
            bootstrapUpdateInProgress: true,
            operationalProcessVerificationUnavailable: false,
            didObserveExternalRunnerDuringConformance: false,
            hasTerminalSteamUIFailure: false
        ))
        XCTAssertFalse(SteamManager.shouldDeferSteamUIVerification(
            bootstrapUpdateInProgress: true,
            operationalProcessVerificationUnavailable: true,
            didObserveExternalRunnerDuringConformance: false,
            hasTerminalSteamUIFailure: true
        ))
        XCTAssertFalse(SteamManager.shouldDeferSteamUIVerification(
            bootstrapUpdateInProgress: true,
            operationalProcessVerificationUnavailable: true,
            didObserveExternalRunnerDuringConformance: true,
            hasTerminalSteamUIFailure: false
        ))
    }

    func testBootstrapUpdaterEvidenceTrackerRequiresRecentOrAdvancingProgress() {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let missingCursor = SteamLogFileCursor(
            byteCount: 0,
            fileNumber: nil,
            deviceNumber: nil,
            modificationDate: nil,
            trailingSignature: Data(),
            endsAtLineBoundary: true,
            captureState: .missing,
            captureDetail: nil
        )
        var tracker = SteamBootstrapUpdaterEvidenceTracker(
            cursor: SteamBootstrapUpdateSourceCursor(
                stdout: missingCursor,
                bootstrapLog: missingCursor
            )
        )
        func progress(_ identity: String) -> SteamBootstrapUpdateLogAssessment {
            SteamBootstrapUpdateLogAssessment(
                hasProgress: true,
                state: .captured,
                detail: "fixture",
                sources: [],
                progressIdentity: identity,
                observedProgress: true
            )
        }
        func quiet() -> SteamBootstrapUpdateLogAssessment {
            SteamBootstrapUpdateLogAssessment(
                hasProgress: false,
                state: .captured,
                detail: "unrelated noise",
                sources: [],
                progressIdentity: nil
            )
        }
        let unavailableCursor = SteamBootstrapUpdateSourceCursor(
            stdout: SteamLogFileCursor(
                byteCount: 123,
                fileNumber: 456,
                deviceNumber: 789,
                modificationDate: startedAt,
                trailingSignature: Data("unverified".utf8),
                endsAtLineBoundary: true,
                captureState: .captured,
                captureDetail: "must not advance"
            ),
            bootstrapLog: missingCursor
        )
        func transientUnavailable() -> SteamBootstrapUpdateLogAssessment {
            SteamBootstrapUpdateLogAssessment(
                hasProgress: nil,
                state: .unreadable,
                detail: "transient source read failure",
                sources: [
                    SteamBootstrapLogSourceAssessment(
                        url: URL(fileURLWithPath: "/tmp/bootstrap_log.txt"),
                        required: true,
                        state: .unreadable,
                        detail: "fixture",
                        text: ""
                    )
                ],
                progressIdentity: nil,
                nextCursor: unavailableCursor
            )
        }

        XCTAssertEqual(
            tracker.observe(
                assessment: progress("download-10000"),
                at: startedAt,
                idleTimeout: 10
            ).continuity,
            .recentOrAdvancing
        )
        let retainedIdentity = tracker.progressIdentity
        let retainedAdvancedAt = tracker.lastAdvancedAt
        let retainedCursor = tracker.cursor
        var invalidatedGeneration = transientUnavailable()
        invalidatedGeneration.state = .changedDuringRead
        invalidatedGeneration.sources[0].state = .changedDuringRead
        XCTAssertEqual(
            SteamBootstrapUpdaterEvidenceAvailability(
                invalidatedGeneration
            ),
            .unavailable
        )
        XCTAssertEqual(
            tracker.observe(
                assessment: invalidatedGeneration,
                at: startedAt.addingTimeInterval(0.5),
                idleTimeout: 10
            ).continuity,
            .evidenceUnavailable,
            "replacement, truncation, or pre-cursor mutation must not borrow retained updater continuity"
        )
        XCTAssertEqual(tracker.lastAdvancedAt, retainedAdvancedAt)
        XCTAssertEqual(tracker.cursor, retainedCursor)
        XCTAssertEqual(
            SteamBootstrapUpdaterEvidenceAvailability(
                transientUnavailable()
            ),
            .transientlyUnavailable
        )
        let firstTransient = tracker.observe(
            assessment: transientUnavailable(),
            at: startedAt.addingTimeInterval(1),
            idleTimeout: 10
        )
        XCTAssertEqual(firstTransient.state, .inProgress)
        XCTAssertEqual(firstTransient.continuity, .recentOrAdvancing)
        XCTAssertEqual(tracker.progressIdentity, retainedIdentity)
        XCTAssertEqual(tracker.lastAdvancedAt, retainedAdvancedAt)
        XCTAssertEqual(tracker.cursor, retainedCursor)

        let repeatedTransient = tracker.observe(
            assessment: transientUnavailable(),
            at: startedAt.addingTimeInterval(9),
            idleTimeout: 10
        )
        XCTAssertEqual(repeatedTransient.state, .inProgress)
        XCTAssertEqual(repeatedTransient.continuity, .recentOrAdvancing)
        XCTAssertEqual(tracker.lastAdvancedAt, retainedAdvancedAt)

        let staleTransient = tracker.observe(
            assessment: transientUnavailable(),
            at: startedAt.addingTimeInterval(11),
            idleTimeout: 10
        )
        XCTAssertEqual(staleTransient.state, .inProgress)
        XCTAssertEqual(staleTransient.continuity, .stale)
        XCTAssertEqual(tracker.lastAdvancedAt, retainedAdvancedAt)
        XCTAssertEqual(
            tracker.observe(
                assessment: quiet(),
                at: startedAt.addingTimeInterval(11),
                idleTimeout: 10
            ).continuity,
            .stale
        )
        XCTAssertEqual(
            tracker.observe(
                assessment: progress("download-20000"),
                at: startedAt.addingTimeInterval(12),
                idleTimeout: 10
            ).continuity,
            .recentOrAdvancing
        )
    }

    func testCancelledOperationalNVIDIALaunchObservationKeepsSuccessfulSessionUntilPrefixInactivity() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path:
                "ForgePlayDetachedNVIDIARendererLifetime-" +
                UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let postDispatchMarker = temporaryRoot.appending(
            path: "nvidia-post-dispatch.marker"
        )
        let startupObservationMarker = temporaryRoot.appending(
            path: "nvidia-startup-observation.marker"
        )
        let observedLauncher = temporaryRoot.appending(
            path: "BundledResources/Runners/ForgePlayRuntime/wine/bin/wine"
        )
        let observedSteamCommand =
            "\(observedLauncher.path) C:\\Program Files (x86)\\Steam\\steam.exe WINEPREFIX=\(prefix.path)"
        let observedWebHelperCommand =
            "\(observedLauncher.path) C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win7x64\\steamwebhelper.exe --no-sandbox WINEPREFIX=\(prefix.path)"
        let prefixActivity = GatedCompatibilityPrefixExitWaiter()
        let inputProtection = DetachedHandoffInputProtectionDriver()
        let steamManager = SteamManager(
            pathManager: pathManager,
            runner: makeCuratedRuntimeRunner(),
            processSnapshotProvider: {
                guard FileManager.default.fileExists(
                    atPath: postDispatchMarker.path
                ) else {
                    return SteamLaunchProcessSnapshot(processes: [])
                }
                try? Data("observing\n".utf8).write(
                    to: startupObservationMarker
                )
                return SteamLaunchProcessSnapshot(processes: [
                    SteamLaunchObservedProcess(
                        processID: 4_242,
                        command: observedSteamCommand,
                        processStartedAtUnixMicroseconds: 980_001
                    ),
                    SteamLaunchObservedProcess(
                        processID: 4_243,
                        command: observedWebHelperCommand,
                        processStartedAtUnixMicroseconds: 980_002
                    )
                ])
            },
            processEvidenceTimeout: 0.2,
            processEvidencePollInterval: 0.1,
            renderingObservationTimeout: 0,
            steamUIStartupObservationTimeout: 5,
            steamUIStartupObservationPollInterval: 0.1,
            compatibilityPrefixExitWaiter: { _, timeout, pollInterval in
                await prefixActivity.next(
                    timeout: timeout,
                    pollInterval: pollInterval
                )
            },
            detachedHandoffManagedWineReadbackProvider: { _ in
                ManagedWineChildSynchronizationReadback(
                    processIdentifier: 4_242,
                    selection: .automatic,
                    backend: .server
                )
            },
            managedWineLaunchProcessIdentityProvider: { _, _ in
                guard FileManager.default.fileExists(
                    atPath: postDispatchMarker.path
                ) else { return [] }
                return [
                    ManagedWineLaunchProcessIdentity(
                        processID: 4_242,
                        processStartedAtUnixMicroseconds: 980_001,
                        executableURL: observedLauncher
                    ),
                    ManagedWineLaunchProcessIdentity(
                        processID: 4_243,
                        processStartedAtUnixMicroseconds: 980_002,
                        executableURL: observedLauncher
                    )
                ]
            },
            managedWineJournalProcessSnapshotProvider: { identities in
                guard FileManager.default.fileExists(
                    atPath: postDispatchMarker.path
                ) else {
                    return SteamLaunchProcessSnapshot(processes: [])
                }
                return SteamLaunchProcessSnapshot(processes: identities.map {
                    identity in
                    SteamLaunchObservedProcess(
                        processID: identity.processID,
                        command: identity.processID == 4_242
                            ? observedSteamCommand
                            : observedWebHelperCommand,
                        evidenceSource: .managedWineJournal,
                        processStartedAtUnixMicroseconds:
                            identity.processStartedAtUnixMicroseconds
                    )
                })
            },
            gameInputProtectionDriverFactory: { inputProtection },
            gameInputProtectionPolicyStore: GameInputProtectionPolicyStore(
                initialPolicy: GameInputProtectionPolicy(
                    blockAppSwitchingShortcuts: true
                )
            ),
            steamClientServicePreparer: { _, _, _ in }
        )
        let dosdevices = prefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        let steamDirectory = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        let runtimeRoot = temporaryRoot.appending(
            path: "BundledResources/Runners/ForgePlayRuntime",
            directoryHint: .isDirectory
        )
        let wineRoot = runtimeRoot.appending(
            path: "wine",
            directoryHint: .isDirectory
        )
        let launcherDirectory = wineRoot.appending(
            path: "bin",
            directoryHint: .isDirectory
        )
        let renderer = runtimeRoot.appending(
            path: "Frameworks/renderer/d3dmetal",
            directoryHint: .isDirectory
        )
        let launcher = launcherDirectory.appending(path: "wine")
        let invocationLog = temporaryRoot.appending(
            path: "cancelled-nvidia-launch-invocations.log"
        )
        let detachedHelper = wineRoot.appending(
            path:
                "lib/wine/x86_64-windows/" +
                "forgeplay-steam-launcher.exe"
        )

        let systemDirectories = try createSteamWindowsSystemDirectories(
            in: prefix
        )
        try FileManager.default.createDirectory(
            at: dosdevices,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: steamDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: launcherDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: renderer,
            withIntermediateDirectories: true
        )
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("forgeplay detached launcher fixture".utf8).write(
            to: detachedHelper
        )
        try Data("steam".utf8).write(
            to: steamDirectory.appending(path: "steam.exe")
        )
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        if [ "$1" = "--version" ]; then
          printf 'wine-11.12\\n'
          exit 0
        fi
        if [ "$1" = "wineserver" ]; then
          exit 0
        fi
        if [ "$2" = "-shutdown" ]; then
          exit 0
        fi
        case "$*" in
          *steam.exe*)
            : > "\(postDispatchMarker.path)"
            log_dir="$WINEPREFIX/drive_c/Program Files (x86)/Steam/logs"
            mkdir -p "$log_dir"
            timestamp="$(date '+[%Y-%m-%d %H:%M:%S]')"
            printf '%s BrowserReady: handle:65536\\r\\n' "$timestamp" > "$log_dir/steamui_html.txt"
            printf '%s [ gpu_compositing ]: enabled_on\\r\\n' "$timestamp" > "$log_dir/webhelper_gpu.txt"
            printf '%s SP DesktopLoginWindow_uid0-Steam: WasHidden 0: (0, 0) 700x440\\r\\n' "$timestamp" > "$log_dir/webhelper.txt"
            ;;
        esac
        exit 0
        """.write(
            to: launcher,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        try await applySteamLaunchPolicy(
            steamManager: steamManager,
            prefix: prefix,
            launcher: launcher
        )
        try? FileManager.default.removeItem(at: invocationLog)
        try? FileManager.default.removeItem(at: postDispatchMarker)
        try? FileManager.default.removeItem(at: startupObservationMarker)

        var restorationLeaseEvents: [String] = []
        let restorationLease = SteamCompatibilityRestorationPrefixLease(
            prepareForMutation: {
                restorationLeaseEvents.append("exclusive-mutation")
            },
            release: {
                restorationLeaseEvents.append("release")
            }
        )
        defer { restorationLease.release() }
        let leaseTransition = SteamPrefixExecutionLeaseTransition(
            prepareForMutation: {},
            prepareForExecution: {},
            restorationLease: restorationLease
        )

        let launchTask = Task {
            try await steamManager.launchSteam(
                runtimeExecutable: launcher,
                verificationMode: .operational,
                rendererPolicy: .d3dMetal,
                compatibilitySelection: SteamPrelaunchCompatibilitySelection(
                    rendererSelection: .d3dMetalNVIDIA,
                    networkSelection: .standard,
                    audioInputSelection: .enabled
                ),
                prefixExecutionLeaseTransition: leaseTransition
            )
        }
        for _ in 0..<500 where !FileManager.default.fileExists(
            atPath: startupObservationMarker.path
        ) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: startupObservationMarker.path
            ),
            "the launch must enter startup observation before cancellation"
        )
        launchTask.cancel()
        let result: ProcessRunResult
        do {
            result = try await launchTask.value
        } catch {
            await prefixActivity.markInactive()
            throw error
        }
        let invocations = try String(
            contentsOf: invocationLog,
            encoding: .utf8
        ).split(whereSeparator: \.isNewline).map(String.init)

        XCTAssertTrue(launchTask.isCancelled)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.waitedForExit)
        XCTAssertEqual(result.outcome, .exited)
        XCTAssertEqual(result.processExitCode, 0)
        XCTAssertNil(result.forgePlayStatusCode)
        XCTAssertEqual(result.steamUIVerificationState, .launchedButUnverified)
        XCTAssertEqual(
            SteamLaunchDispatchDisposition.resolve(result),
            .successfulForgePlayLauncherHandoff
        )
        XCTAssertEqual(inputProtection.boundProcessIdentifier, 4_242)
        XCTAssertEqual(
            result.managedWineChildSynchronizationReadback?
                .processIdentifier,
            4_242
        )
        XCTAssertTrue(
            result.inputCompatibilityReceipt?
                .isLifecycleAdmissionVerified == true
        )
        XCTAssertFalse(result.inputProtectionDegradedForDetachedHandoff)
        XCTAssertEqual(
            Array(result.arguments.prefix(3)),
            [detachedHelper.path, "--detach", "--"]
        )
        XCTAssertTrue(restorationLease.isTransferred)
        let steamLaunchIndex = try XCTUnwrap(
            invocations.firstIndex {
                $0.contains("C:\\Program Files (x86)\\Steam\\steam.exe") &&
                    !$0.contains("-shutdown")
            }
        )
        XCTAssertEqual(
            invocations.filter {
                $0.contains("C:\\Program Files (x86)\\Steam\\steam.exe") &&
                    !$0.contains("-shutdown")
            }.count,
            1
        )
        XCTAssertTrue(
            invocations.prefix(upTo: steamLaunchIndex)
                .contains("wineserver --kill=\(SIGTERM)")
        )
        XCTAssertFalse(
            invocations.dropFirst(steamLaunchIndex + 1)
                .contains("wineserver --kill=\(SIGTERM)"),
            invocations.joined(separator: "\n")
        )

        var prefixActivitySnapshot = await prefixActivity.snapshot()
        for _ in 0..<10_000 where
            prefixActivitySnapshot.timeouts.isEmpty {
            await Task.yield()
            prefixActivitySnapshot = await prefixActivity.snapshot()
        }
        XCTAssertFalse(prefixActivitySnapshot.inactive)
        XCTAssertEqual(prefixActivitySnapshot.timeouts, [30])
        XCTAssertEqual(
            prefixActivitySnapshot.pollIntervals,
            [0.2]
        )
        XCTAssertTrue(restorationLeaseEvents.isEmpty)
        XCTAssertEqual(inputProtection.restoreCallCount, 0)

        let backupDirectory = prefix.appending(
            path: "drive_c/ForgePlay/RendererBackups/system32",
            directoryHint: .isDirectory
        )
        let moduleSessionDirectory = backupDirectory.appending(
            path: ".forgeplay-nvidia-metalfx-session",
            directoryHint: .isDirectory
        )
        let registryMarker = prefix.appending(
            path:
                "drive_c/ForgePlay/RendererBackups/" +
                SteamRendererPolicyManager
                    .nvidiaMetalFXRegistrySessionMarkerName
        )
        let sourceAndStagedModules = [
            (
                renderer.appending(
                    path:
                        D3DMetalNVAPIAliasContract
                            .windowsAliasRelativePath
                ),
                systemDirectories.system32.appending(path: "nvapi.dll")
            ),
            (
                renderer.appending(
                    path: "wine/x86_64-windows/nvapi64.dll"
                ),
                systemDirectories.system32.appending(path: "nvapi64.dll")
            ),
            (
                renderer.appending(
                    path: "wine/x86_64-windows/nvngx-on-metalfx.dll"
                ),
                systemDirectories.system32.appending(path: "nvngx.dll")
            )
        ]
        for (source, staged) in sourceAndStagedModules {
            XCTAssertTrue(
                FileSystemItemPolicy.isRegularNonSymlinkFile(source),
                source.path
            )
            XCTAssertEqual(
                try? Data(contentsOf: staged),
                try? Data(contentsOf: source),
                staged.path
            )
        }
        XCTAssertTrue(
            FileSystemItemPolicy.isRegularNonSymlinkFile(registryMarker)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: moduleSessionDirectory.path
            )
        )
        let stagedSystemRegistry = (try? String(
            contentsOf: prefix.appending(path: "system.reg"),
            encoding: .utf8
        )) ?? ""
        XCTAssertEqual(
            WineUserRegistrySnapshot(contents: stagedSystemRegistry).value(
                forRegistryPath:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreRegistryPath,
                valueName:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreFullPathValueName
            ),
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreSystem32Path
        )

        await prefixActivity.markInactive()
        for _ in 0..<500 where restorationLeaseEvents.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            restorationLeaseEvents,
            ["exclusive-mutation", "release"]
        )
        XCTAssertEqual(inputProtection.restoreCallCount, 1)
        for (_, staged) in sourceAndStagedModules {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: staged.path),
                staged.path
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: registryMarker.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: moduleSessionDirectory.path
            )
        )
        let restoredSystemRegistry = (try? String(
            contentsOf: prefix.appending(path: "system.reg"),
            encoding: .utf8
        )) ?? ""
        XCTAssertNil(
            WineUserRegistrySnapshot(contents: restoredSystemRegistry).value(
                forRegistryPath:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreRegistryPath,
                valueName:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreFullPathValueName
            )
        )
        prefixActivitySnapshot = await prefixActivity.snapshot()
        XCTAssertTrue(prefixActivitySnapshot.inactive)
        XCTAssertEqual(
            prefixActivitySnapshot.timeouts.count,
            prefixActivitySnapshot.pollIntervals.count
        )
        XCTAssertEqual(
            prefixActivitySnapshot.timeouts.first,
            30
        )
        XCTAssertEqual(
            prefixActivitySnapshot.pollIntervals.first,
            0.2
        )
        let trailingTimeouts = Array(
            prefixActivitySnapshot.timeouts.dropFirst()
        )
        let trailingPollIntervals = Array(
            prefixActivitySnapshot.pollIntervals.dropFirst()
        )
        XCTAssertEqual(
            trailingTimeouts,
            Array(repeating: 0, count: trailingTimeouts.count),
            "Only nonblocking game-diagnostic inactivity readback may follow renderer restoration"
        )
        XCTAssertEqual(
            trailingPollIntervals,
            Array(repeating: 0.1, count: trailingPollIntervals.count),
            "The game-diagnostic inactivity readback must retain its bounded polling policy"
        )
        restorationLease.release()
        XCTAssertEqual(
            restorationLeaseEvents,
            ["exclusive-mutation", "release"]
        )
    }

    func testOperationalRendererRestorationWaitsWhenShutdownFailsAndPrefixRemainsActive() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path:
                "ForgePlayActivePrefixRendererRestoration-" +
                UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let prefixActivity = DeterministicCompatibilityPrefixExitWaiter(
            observations: [false, false]
        )
        let steamManager = SteamManager(
            pathManager: pathManager,
            runner: makeCuratedRuntimeRunner(),
            processSnapshotProvider: {
                SteamLaunchProcessSnapshot(processes: [])
            },
            processEvidenceTimeout: 0,
            renderingObservationTimeout: 0,
            steamUIStartupObservationTimeout: 0,
            compatibilityPrefixExitWaiter: { _, timeout, _ in
                await prefixActivity.next(timeout: timeout)
            },
            gameInputProtectionPolicyStore: GameInputProtectionPolicyStore(
                initialPolicy: .disabled
            ),
            steamClientServicePreparer: { _, _, _ in }
        )
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        let steamDirectory = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        let runtimeRoot = temporaryRoot.appending(
            path: "BundledResources/Runners/ForgePlayRuntime",
            directoryHint: .isDirectory
        )
        let wineRoot = runtimeRoot.appending(
            path: "wine",
            directoryHint: .isDirectory
        )
        let launcherDirectory = wineRoot.appending(
            path: "bin",
            directoryHint: .isDirectory
        )
        let renderer = runtimeRoot.appending(
            path: "Frameworks/renderer/d3dmetal",
            directoryHint: .isDirectory
        )
        let launcher = launcherDirectory.appending(path: "wine")
        let invocationLog = temporaryRoot.appending(
            path: "active-prefix-renderer-restoration-invocations.log"
        )
        let postDispatchMarker = prefix.appending(path: ".post-dispatch")

        let systemDirectories = try createSteamWindowsSystemDirectories(
            in: prefix
        )
        try FileManager.default.createDirectory(
            at: dosdevices,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: steamDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: launcherDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: renderer,
            withIntermediateDirectories: true
        )
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("steam".utf8).write(
            to: steamDirectory.appending(path: "steam.exe")
        )
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        \(steamRegistryRecordingShellPreamble())
        if [ "$1" = "--version" ]; then
          printf 'wine-11.12\\n'
          exit 0
        fi
        if [ "$1" = "wineserver" ]; then
          if [ -f "\(postDispatchMarker.path)" ]; then
            exit 9
          fi
          exit 0
        fi
        case "$*" in
          *steam.exe*)
            : > "\(postDispatchMarker.path)"
            exit 9
            ;;
        esac
        exit 0
        """.write(
            to: launcher,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        try await applySteamLaunchPolicy(
            steamManager: steamManager,
            prefix: prefix,
            launcher: launcher
        )
        try? FileManager.default.removeItem(at: invocationLog)
        try? FileManager.default.removeItem(at: postDispatchMarker)

        var leaseTransitionEvents: [String] = []
        let leaseTransition = SteamPrefixExecutionLeaseTransition(
            prepareForMutation: {
                leaseTransitionEvents.append("mutation")
            },
            prepareForExecution: {
                leaseTransitionEvents.append("execution")
            }
        )

        do {
            _ = try await steamManager.launchSteam(
                runtimeExecutable: launcher,
                verificationMode: .operational,
                rendererPolicy: .d3dMetal,
                compatibilitySelection: SteamPrelaunchCompatibilitySelection(
                    rendererSelection: .d3dMetalNVIDIA,
                    networkSelection: .standard,
                    audioInputSelection: .enabled
                ),
                prefixExecutionLeaseTransition: leaseTransition
            )
            XCTFail("active managed prefix must prevent renderer restoration")
        } catch {
            let underlyingError =
                (error as? ProcessExecutionEvidenceError)?.underlyingError ??
                error
            guard let steamLaunchError = underlyingError as? SteamLaunchError,
                  case .rendererLifecycleFailed(let failure) =
                    steamLaunchError else {
                XCTFail(
                    "unexpected active-prefix restoration error: \(error)"
                )
                return
            }
            XCTAssertEqual(failure.phase, .postLaunchRestoration)
            XCTAssertEqual(failure.operation, .sessionRestoration)
            XCTAssertTrue(
                failure.detail.contains(
                    "renderer-restoration-managed-prefix-still-active"
                ),
                failure.detail
            )
            XCTAssertTrue(
                failure.processResults.contains {
                    $0.actionName == "shutdownWinePrefix" && !$0.succeeded
                }
            )
        }

        XCTAssertEqual(leaseTransitionEvents, ["mutation", "execution"])
        let prefixActivitySnapshot = await prefixActivity.snapshot()
        XCTAssertTrue(prefixActivitySnapshot.remaining.isEmpty)
        XCTAssertEqual(prefixActivitySnapshot.timeouts, [30, 0])

        let registryMarker = prefix.appending(
            path:
                "drive_c/ForgePlay/RendererBackups/" +
                SteamRendererPolicyManager
                    .nvidiaMetalFXRegistrySessionMarkerName
        )
        let moduleSessionDirectory = prefix.appending(
            path:
                "drive_c/ForgePlay/RendererBackups/system32/" +
                ".forgeplay-nvidia-metalfx-session",
            directoryHint: .isDirectory
        )
        XCTAssertTrue(
            FileSystemItemPolicy.isRegularNonSymlinkFile(registryMarker)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: moduleSessionDirectory.path
            )
        )
        let sourceAndStagedModules = [
            (
                renderer.appending(
                    path:
                        D3DMetalNVAPIAliasContract
                            .windowsAliasRelativePath
                ),
                systemDirectories.system32.appending(path: "nvapi.dll")
            ),
            (
                renderer.appending(
                    path: "wine/x86_64-windows/nvapi64.dll"
                ),
                systemDirectories.system32.appending(path: "nvapi64.dll")
            ),
            (
                renderer.appending(
                    path: "wine/x86_64-windows/nvngx-on-metalfx.dll"
                ),
                systemDirectories.system32.appending(path: "nvngx.dll")
            )
        ]
        for (source, staged) in sourceAndStagedModules {
            XCTAssertEqual(
                try Data(contentsOf: staged),
                try Data(contentsOf: source),
                staged.path
            )
        }
        let systemRegistry = try String(
            contentsOf: prefix.appending(path: "system.reg"),
            encoding: .utf8
        )
        XCTAssertEqual(
            WineUserRegistrySnapshot(contents: systemRegistry).value(
                forRegistryPath:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreRegistryPath,
                valueName:
                    SteamRendererPolicyManager
                        .nvidiaMetalFXNGXCoreFullPathValueName
            ),
            SteamRendererPolicyManager.nvidiaMetalFXNGXCoreSystem32Path
        )
        let invocations = try String(
            contentsOf: invocationLog,
            encoding: .utf8
        ).split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertFalse(
            invocations.contains {
                $0.hasPrefix("reg delete ") &&
                    $0.contains(
                        SteamRendererPolicyManager
                            .nvidiaMetalFXNGXCoreRegistryPath
                    )
            },
            invocations.joined(separator: "\n")
        )
    }

    func testOperationalLaunchCleansUpWhenLaunchCommandFails() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayOperationalSteamFailureRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let runtimeRoot = temporaryRoot.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcherDirectory = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        let invocationLog = temporaryRoot.appending(path: "operational-steam-failure-invocations.log")

        try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("steam".utf8).write(
            to: steamDirectory.appending(path: "steam.exe")
        )
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        if [ "$1" = "--version" ]; then
          printf 'wine-11.12\\n'
          exit 0
        fi
        if [ "$1" = "wineserver" ]; then
          exit 0
        fi
        case "$*" in
          *steam.exe*)
            exit 9
            ;;
        esac
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try await applySteamLaunchPolicy(steamManager: steamManager, prefix: prefix, launcher: launcher)
        try? FileManager.default.removeItem(at: invocationLog)

        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .operational,
            rendererPolicy: .d3dMetal
        )
        let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let diagnostics = try String(contentsOf: try XCTUnwrap(result.diagnosticLog), encoding: .utf8)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.exitCode, 9)
        XCTAssertEqual(result.steamUIVerificationState, .failed)
        XCTAssertTrue(diagnostics.contains("Status: FAILED"), diagnostics)
        XCTAssertTrue(diagnostics.contains("failed-launch-command"), diagnostics)
        XCTAssertTrue(diagnostics.contains("Post-failure Steam Prefix process shutdown:"), diagnostics)
        let steamLaunchIndex = try XCTUnwrap(
            invocations.lastIndex {
                $0.contains("C:\\Program Files (x86)\\Steam\\steam.exe") && !$0.contains("-shutdown")
            }
        )
        XCTAssertTrue(
            invocations.dropFirst(steamLaunchIndex + 1).contains("wineserver --kill=\(SIGTERM)"),
            invocations.joined(separator: "\n")
        )
    }

    func testOperationalLaunchDoesNotRestartOrStopSessionWhenCEFFailureIsObserved() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamSharedContextRecoveryRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let logDirectory = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let runtimeRoot = temporaryRoot.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcherDirectory = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        let detachedHelper = wineRoot.appending(
            path: "lib/wine/x86_64-windows/forgeplay-steam-launcher.exe"
        )
        let launchCountFile = temporaryRoot.appending(path: "steam-shared-context-launch-count.txt")
        let liveWebHelperProcessIDFile = temporaryRoot.appending(path: "live-webhelper-process-id.txt")
        let invocationLog = temporaryRoot.appending(path: "steam-incomplete-diagnostics-invocations.log")
        let unsafeShaderLogTarget = temporaryRoot.appending(path: "untrusted-shader-log.txt")
        let webHelperCommand = #"C:\Program Files (x86)\Steam\bin\cef\cef.win7x64\steamwebhelper.exe --no-sandbox"#
        let liveWebHelperCommand =
            "\(launcher.path) \(webHelperCommand) WINEPREFIX=\(prefix.path)"

        try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("forgeplay detached launcher fixture".utf8).write(
            to: detachedHelper
        )
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try "untrusted shader evidence\n".write(
            to: unsafeShaderLogTarget,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: logDirectory.appending(path: "shader_log.txt"),
            withDestinationURL: unsafeShaderLogTarget
        )
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        printf '%s\n' "$*" >> "\(invocationLog.path)"
        if [ "$1" = "--version" ]; then
          printf 'wine-11.12\\n'
          exit 0
        fi
        if [ "$1" = "wineserver" ]; then
          exit 0
        fi
        case "$*" in
          *steam.exe*shutdown*)
            exit 0
            ;;
          *steam.exe*)
            count=0
            if [ -f "\(launchCountFile.path)" ]; then
              count="$(cat "\(launchCountFile.path)")"
            fi
            count=$((count + 1))
            printf '%s' "$count" > "\(launchCountFile.path)"
            mkdir -p "\(logDirectory.path)"
            timestamp="$(date '+[%Y-%m-%d %H:%M:%S]')"
            if [ "$count" -eq 1 ]; then
              printf '%s BrowserReady: handle:65536\\r\\n' "$timestamp" >> "\(logDirectory.appending(path: "steamui_html.txt").path)"
              printf '%s ContextResult::kFatalFailure: Failed to create shared context for virtualization\\r\\n' "$timestamp" >> "\(logDirectory.appending(path: "cef_log.txt").path)"
            else
              printf '%s BrowserReady: handle:65536\\r\\n' "$timestamp" >> "\(logDirectory.appending(path: "steamui_html.txt").path)"
              printf '%s [ gpu_compositing ]: enabled_on\\r\\n' "$timestamp" >> "\(logDirectory.appending(path: "webhelper_gpu.txt").path)"
              printf '%s SP DesktopLoginWindow_uid0-Steam: WasHidden 0: (0, 0) 700x440\\r\\n' "$timestamp" >> "\(logDirectory.appending(path: "webhelper.txt").path)"
            fi
            /bin/sleep 5 &
            live_webhelper_pid=$!
            printf '%s' "$live_webhelper_pid" > "\(liveWebHelperProcessIDFile.path)"
            (
              sleep 0.3
              observation_path="${FORGEPLAY_PROCESS_OBSERVATION_FILE#Z:}"
              observation_path="$(printf '%s' "$observation_path" | tr '\\' '/')"
              printf '%s\\t%s\\t%s\\n' \\
                'FORGEPLAY_PROCESS_V1' \\
                "$live_webhelper_pid" \\
                '\(webHelperCommand)' \\
                >> "$observation_path"
            ) &
            exit 0
            ;;
        esac
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try installAuthenticatedRuntimePayloadFixture(for: launcher)
        let authenticatedRuntimeContext = try RuntimeManifestResolver()
            .authenticatedContext(for: launcher)

        let steamManager = makeSteamManager(
            pathManager: pathManager,
            processEvidenceTimeout: 2,
            processEvidencePollInterval: 0.1,
            steamUIStartupObservationTimeout: 1,
            steamUIStartupObservationPollInterval: 0.1,
            processSnapshotProvider: {
                guard let processIDText = try? String(
                    contentsOf: liveWebHelperProcessIDFile,
                    encoding: .utf8
                ),
                let processID = Int32(
                    processIDText.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                ) else {
                    return SteamLaunchProcessSnapshot(processes: [])
                }
                return SteamLaunchProcessSnapshot(processes: [
                    SteamLaunchObservedProcess(
                        processID: 70_001,
                        command:
                            "\(launcher.path) C:\\Program Files (x86)\\Steam\\steam.exe WINEPREFIX=\(prefix.path)",
                        processStartedAtUnixMicroseconds: 930_001
                    ),
                    SteamLaunchObservedProcess(
                        processID: processID,
                        command: liveWebHelperCommand,
                        processStartedAtUnixMicroseconds: 930_002
                    )
                ])
            },
            detachedHandoffManagedWineReadbackProvider: { _ in
                ManagedWineChildSynchronizationReadback(
                    processIdentifier: 4_242,
                    selection: .automatic,
                    backend: .server
                )
            },
            managedWineLaunchProcessIdentityProvider: { _, _ in
                var identities: Set<ManagedWineLaunchProcessIdentity> = [
                    ManagedWineLaunchProcessIdentity(
                        processID: 70_001,
                        processStartedAtUnixMicroseconds: 930_001,
                        executableURL: launcher
                    )
                ]
                if let processIDText = try? String(
                    contentsOf: liveWebHelperProcessIDFile,
                    encoding: .utf8
                ), let processID = Int32(
                    processIDText.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                ) {
                    identities.insert(ManagedWineLaunchProcessIdentity(
                        processID: processID,
                        processStartedAtUnixMicroseconds: 930_002,
                        executableURL: launcher
                    ))
                }
                return identities
            },
            managedWineJournalProcessSnapshotProvider: { identities in
                SteamLaunchProcessSnapshot(processes: identities.map {
                    identity in
                    SteamLaunchObservedProcess(
                        processID: identity.processID,
                        command: identity.processID == 70_001
                            ? "\(launcher.path) C:\\Program Files (x86)\\Steam\\steam.exe WINEPREFIX=\(prefix.path)"
                            : liveWebHelperCommand,
                        evidenceSource: .managedWineJournal,
                        processStartedAtUnixMicroseconds:
                            identity.processStartedAtUnixMicroseconds
                    )
                })
            },
            runtimeLaunchObjectIdentityProvider: { executable in
                try authenticatedRuntimeContext.launchObjectIdentity(for: executable)
            }
        )
        try await applySteamLaunchPolicy(steamManager: steamManager, prefix: prefix, launcher: launcher)
        try? FileManager.default.removeItem(at: launchCountFile)
        try? FileManager.default.removeItem(at: liveWebHelperProcessIDFile)
        try? FileManager.default.removeItem(at: invocationLog)

        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .operational,
            rendererPolicy: .d3dMetal
        )
        let liveWebHelperProcessID = try XCTUnwrap(
            pid_t(
                String(contentsOf: liveWebHelperProcessIDFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        defer { _ = Darwin.kill(liveWebHelperProcessID, SIGKILL) }
        let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.waitedForExit)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try String(contentsOf: launchCountFile, encoding: .utf8), "1")
        XCTAssertEqual(result.steamUIStartupRecoveryAttemptCount, 0)
        XCTAssertNil(result.steamUIStartupRecoveryReason)
        XCTAssertEqual(result.steamUIVerificationState, .launchedButUnverified)
        XCTAssertTrue(result.diagnosticCaptureWarning?.contains("shader_log.txt") == true)
        XCTAssertTrue(result.diagnosticCaptureWarning?.contains("unsafe") == true)
        let diagnostics = try String(contentsOf: try XCTUnwrap(result.diagnosticLog), encoding: .utf8)
        let observationLog = try String(
            contentsOf: try XCTUnwrap(result.processObservationLog),
            encoding: .utf8
        )
        XCTAssertTrue(diagnostics.contains("Status: LAUNCHED"), diagnostics)
        XCTAssertTrue(diagnostics.contains("shader_log.txt: unsafe"), diagnostics)
        XCTAssertTrue(diagnostics.contains("Diagnostic evidence inspection was incomplete"), diagnostics)
        XCTAssertTrue(observationLog.contains(webHelperCommand), observationLog)
        XCTAssertNil(result.steamUISurface)
        XCTAssertFalse(diagnostics.contains("screen-final.png"), diagnostics)
        XCTAssertFalse(diagnostics.contains("Post-failure Steam Prefix process shutdown:"), diagnostics)
        let steamLaunchInvocations = invocations.filter {
            $0.contains("C:\\Program Files (x86)\\Steam\\steam.exe") &&
                !$0.contains("-shutdown")
        }
        XCTAssertEqual(
            steamLaunchInvocations.count,
            1,
            "CEF/UI diagnostics must not synthesize a second Steam launch"
        )
        let steamLaunchIndex = try XCTUnwrap(
            invocations.firstIndex {
                $0.contains("C:\\Program Files (x86)\\Steam\\steam.exe") && !$0.contains("-shutdown")
            }
        )
        XCTAssertTrue(
            invocations.prefix(upTo: steamLaunchIndex)
                .contains("wineserver --kill=\(SIGTERM)"),
            "the explicit preflight cleanup must still precede the user launch"
        )
        XCTAssertFalse(
            invocations.dropFirst(steamLaunchIndex + 1).contains("wineserver --kill=\(SIGTERM)"),
            invocations.joined(separator: "\n")
        )
    }

    func testConformanceLaunchStopsSessionWhenOtherwiseSuccessfulDiagnosticsEvidenceIsIncomplete() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayConformanceIncompleteDiagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let steamLogs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let cefDirectory = steamDirectory.appending(path: "bin/cef/cef.win7x64", directoryHint: .isDirectory)
        let runtimeRoot = temporaryRoot.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcherDirectory = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        let invocationLog = temporaryRoot.appending(path: "conformance-incomplete-diagnostics-invocations.log")
        let unsafeShaderLogTarget = temporaryRoot.appending(path: "untrusted-conformance-shader-log.txt")
        let steamCommand = "\(launcher.path) C:\\Program Files (x86)\\Steam\\steam.exe WINEPREFIX=\(prefix.path)"
        let webHelperCommand = "\(launcher.path) C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win7x64\\steamwebhelper.exe --no-sandbox --in-process-gpu --disable-gpu WINEPREFIX=\(prefix.path)"
        let processSnapshot = SteamLaunchProcessSnapshot(processes: [
            SteamLaunchObservedProcess(processID: 81_001, command: steamCommand),
            SteamLaunchObservedProcess(processID: 81_002, command: webHelperCommand)
        ])

        try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cefDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try Data("valve webhelper".utf8).write(to: cefDirectory.appending(path: "steamwebhelper.exe"))
        try Data("cef runtime".utf8).write(to: cefDirectory.appending(path: "libcef.dll"))
        try "untrusted shader evidence\n".write(
            to: unsafeShaderLogTarget,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: steamLogs.appending(path: "shader_log.txt"),
            withDestinationURL: unsafeShaderLogTarget
        )
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        printf '%s\n' "$*" >> "\(invocationLog.path)"
        if [ "$1" = "--version" ]; then
          printf 'wine-11.12\n'
          exit 0
        fi
        if [ "$1" = "cmd" ] && [ "$2" = "/c" ]; then
          printf 'Microsoft Windows 10.0.19045\n'
          exit 0
        fi
        if [ "$1" = "wineserver" ]; then
          exit 0
        fi
        if [ "$2" = "-shutdown" ]; then
          exit 0
        fi
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let steamManager = makeSteamManager(
            pathManager: pathManager,
            processSnapshotProvider: { processSnapshot },
            screenEvidenceProvider: { result in
                let screenshot = result.stderrLog
                    .deletingPathExtension()
                    .appendingPathExtension("diagnostics")
                    .appending(path: "screen-final.png")
                do {
                    try FileManager.default.createDirectory(
                        at: screenshot.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data("test screenshot evidence".utf8).write(to: screenshot)
                    return SteamLaunchScreenEvidence(
                        screenshotURL: screenshot,
                        state: .verifiedWindowsSteamUI,
                        surface: .library,
                        recognizedText: ["STORE", "LIBRARY", "COMMUNITY"],
                        message: "deterministic verified Windows Steam UI test evidence"
                    )
                } catch {
                    return SteamLaunchScreenEvidence(
                        screenshotURL: screenshot,
                        state: .captureFailed,
                        recognizedText: [],
                        message: "test screenshot evidence could not be persisted: \(error)"
                    )
                }
            }
        )
        try await applySteamLaunchPolicy(steamManager: steamManager, prefix: prefix, launcher: launcher)
        try? FileManager.default.removeItem(at: invocationLog)

        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .conformance,
            rendererPolicy: .d3dMetal
        )
        let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let diagnostics = try String(contentsOf: try XCTUnwrap(result.diagnosticLog), encoding: .utf8)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.processExitCode, 0)
        XCTAssertEqual(result.forgePlayStatusCode, SteamManager.steamUIStartupFailureExitCode)
        XCTAssertEqual(SteamUIVerificationState.inferred(from: result), .failed)
        XCTAssertTrue(result.diagnosticCaptureWarning?.contains("shader_log.txt") == true)
        XCTAssertTrue(result.diagnosticCaptureWarning?.contains("unsafe") == true)
        XCTAssertTrue(diagnostics.contains("Status: FAILED"), diagnostics)
        XCTAssertTrue(diagnostics.contains("shader_log.txt: unsafe"), diagnostics)
        XCTAssertFalse(diagnostics.contains("failed-visible-ui-not-verified"), diagnostics)
        let evidence = try ProcessRunEvidenceWriter.read(
            from: try XCTUnwrap(result.runEvidenceLog)
        )
        XCTAssertEqual(evidence.forgePlayStatusCode, result.forgePlayStatusCode)
        XCTAssertEqual(evidence.diagnosticLog, result.diagnosticLog?.standardizedFileURL.path)
        XCTAssertEqual(
            Set(evidence.relatedRunEvidenceLogs ?? []),
            Set(result.relatedRunEvidenceLogs.map(\.standardizedFileURL.path))
        )
        XCTAssertEqual(evidence.diagnosticCaptureWarning, result.diagnosticCaptureWarning)
        XCTAssertNotNil(evidence.finalizedAt)
        let steamLaunchIndex = try XCTUnwrap(
            invocations.lastIndex {
                $0.contains("C:\\Program Files (x86)\\Steam\\steam.exe") && !$0.contains("-shutdown")
            }
        )
        XCTAssertTrue(
            invocations.dropFirst(steamLaunchIndex + 1).contains("wineserver --kill=\(SIGTERM)"),
            invocations.joined(separator: "\n")
        )
    }

    func testSteamWebHelperStartupCursorExcludesPreviousRunFailure() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamStartupCursorRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let steamDirectory = temporaryRoot.appending(path: "Steam", directoryHint: .isDirectory)
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let html = logs.appending(path: "steamui_html.txt")
        let console = logs.appending(path: "console_log.txt")
        let webHelper = logs.appending(path: "webhelper.txt")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "Timed out waiting for webhelper init\n".write(to: html, atomically: true, encoding: .utf8)
        try "Failed creating offscreen shared JS context\n".write(to: console, atomically: true, encoding: .utf8)
        try Data().write(to: webHelper)

        let reporter = SteamLaunchDiagnosticsReporter()
        let cursor = reporter.captureSteamWebHelperStartupLogCursor(in: steamDirectory)
        let handle = try FileHandle(forWritingTo: html)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("BrowserReady: handle:65536\n".utf8))
        try handle.close()
        let webHelperHandle = try FileHandle(forWritingTo: webHelper)
        try webHelperHandle.seekToEnd()
        try webHelperHandle.write(contentsOf: Data(
            "SP DesktopLoginWindow_uid0-'Steam': WasHidden 0: (0, 0) 700x440\n".utf8
        ))
        try webHelperHandle.close()

        let observation = reporter.detectSteamWebHelperStartup(in: steamDirectory, since: cursor)

        XCTAssertEqual(observation.state, .provisionalSurface)
        XCTAssertNil(observation.reason)
        XCTAssertTrue(observation.steamUIHTMLTail.contains("BrowserReady: handle:65536"))
        XCTAssertTrue(observation.consoleTail.isEmpty)
        XCTAssertEqual(observation.sharedContextReadiness, .ready)
        XCTAssertEqual(observation.provisionalSurfaceReadiness, .loginWindow)
        XCTAssertEqual(observation.usableUIReadiness, .pending)
    }

    func testSteamWebHelperRendererGraceStartsAtPositiveEvidenceAndResetsForAttemptChange() {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var tracker = SteamWebHelperRendererStabilizationTracker()
        var observation = SteamWebHelperStartupObservation(
            state: .provisionalSurface,
            reason: nil,
            steamUIHTMLTail: [],
            consoleTail: [],
            webHelperTail: [
                "SP DesktopLoginWindow_uid0-Steam: WasHidden 0: (0, 0) 700x440"
            ],
            provisionalSurfaceReadiness: .loginWindow,
            hasPositiveRendererEvidence: false
        )

        XCTAssertFalse(tracker.observePositiveRenderer(
            in: observation,
            at: startedAt,
            requiredInterval: 3
        ))
        XCTAssertFalse(tracker.observePositiveRenderer(
            in: observation,
            at: startedAt.addingTimeInterval(10),
            requiredInterval: 3
        ))

        observation.hasPositiveRendererEvidence = true
        observation.rendererAttemptIdentity = "gpu-child-a"
        XCTAssertFalse(tracker.observePositiveRenderer(
            in: observation,
            at: startedAt.addingTimeInterval(10.1),
            requiredInterval: 3
        ), "ten seconds of geometry must not count toward renderer health")
        XCTAssertFalse(tracker.observePositiveRenderer(
            in: observation,
            at: startedAt.addingTimeInterval(13),
            requiredInterval: 3
        ))

        observation.rendererAttemptIdentity = "gpu-child-b"
        XCTAssertFalse(tracker.observePositiveRenderer(
            in: observation,
            at: startedAt.addingTimeInterval(13.1),
            requiredInterval: 3
        ), "a newer GPU fallback must own a fresh grace interval")
        XCTAssertTrue(tracker.observePositiveRenderer(
            in: observation,
            at: startedAt.addingTimeInterval(16.2),
            requiredInterval: 3
        ))

        observation.hasPositiveRendererEvidence = false
        XCTAssertFalse(tracker.observePositiveRenderer(
            in: observation,
            at: startedAt.addingTimeInterval(17),
            requiredInterval: 3
        ))
        observation.hasPositiveRendererEvidence = true
        XCTAssertFalse(tracker.observePositiveRenderer(
            in: observation,
            at: startedAt.addingTimeInterval(17.1),
            requiredInterval: 3
        ), "loss of the positive renderer report must reset stabilization")
    }

    func testSteamWebHelperStartupCursorDiscardsPrelaunchPartialRowExactlyOnce() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlaySteamStartupPartial-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let steamDirectory = temporaryRoot.appending(
            path: "Steam",
            directoryHint: .isDirectory
        )
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        let html = logs.appending(path: "steamui_html.txt")
        try "pre-launch unfinished row ".write(
            to: html,
            atomically: true,
            encoding: .utf8
        )
        let reporter = SteamLaunchDiagnosticsReporter()
        let cursor = reporter.captureSteamWebHelperStartupLogCursor(
            in: steamDirectory
        )
        XCTAssertFalse(cursor.steamUIHTML.endsAtLineBoundary)

        let handle = try FileHandle(forWritingTo: html)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            "Timed out waiting for webhelper init\n".utf8
        ))
        let discardedSuffix = reporter.detectSteamWebHelperStartup(
            in: steamDirectory,
            since: cursor
        )
        XCTAssertEqual(discardedSuffix.state, .pending)

        try handle.write(contentsOf: Data(
            "Timed out waiting for webhelper init\n".utf8
        ))
        let freshCompleteRow = reporter.detectSteamWebHelperStartup(
            in: steamDirectory,
            since: cursor
        )
        XCTAssertEqual(freshCompleteRow.state, .retryableFailure)
        XCTAssertTrue(
            freshCompleteRow.reason?.contains("timed out waiting") == true
        )
    }

    func testSteamWebHelperSameSecondCrossLogFailureCannotPoisonCurrentPID() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlaySteamSameSecondEpoch-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let steamDirectory = temporaryRoot.appending(
            path: "Steam",
            directoryHint: .isDirectory
        )
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        for name in [
            "webhelper_gpu.txt",
            "steamui_html.txt",
            "steamui_login.txt",
            "console_log.txt",
            "webhelper.txt",
            "cef_log.txt",
            "shader_log.txt",
            "bootstrap_log.txt"
        ] {
            try Data().write(to: logs.appending(path: name))
        }

        let reporter = SteamLaunchDiagnosticsReporter()
        let cursor = reporter.captureSteamWebHelperStartupLogCursor(
            in: steamDirectory
        )
        try """
        [2026-08-14 10:30:30] GPU process started: start count: 0
        [2026-08-14 10:30:30] Initialization of all EGL display types failed.
        [2026-08-14 10:30:30] Exiting GPU process due to errors during initialization
        [2026-08-14 10:30:30] GPU process started: start count: 0
        [2026-08-14 10:30:30] GPU process started: start count: 1
        [2026-08-14 10:30:30] [ gpu_compositing ]: enabled_on
        [2026-08-14 10:30:30] [ webgl ]: enabled
        """.write(
            to: logs.appending(path: "webhelper_gpu.txt"),
            atomically: false,
            encoding: .utf8
        )
        try """
        [2026-08-14 10:30:30] Startup - WebHelper launched pid: 100
        [2026-08-14 10:30:30] Triggering shutdown due to GPU process restarts
        [2026-08-14 10:30:30] Startup - WebHelper launched pid: 200
        [2026-08-14 10:30:30] SP DesktopLoginWindow_uid0-Steam: WasHidden 0: (0, 0) 700x440
        """.write(
            to: logs.appending(path: "webhelper.txt"),
            atomically: false,
            encoding: .utf8
        )
        try "Timed out waiting for webhelper init\n".write(
            to: logs.appending(path: "steamui_html.txt"),
            atomically: false,
            encoding: .utf8
        )
        try "Failed creating offscreen shared JS context\n".write(
            to: logs.appending(path: "console_log.txt"),
            atomically: false,
            encoding: .utf8
        )
        try """
        [100:101:0814/103030.000:ERROR] ContextResult::kFatalFailure: Failed to create shared context
        [200:201:0814/103030.000:INFO] Current WebHelper context initialized
        """.write(
            to: logs.appending(path: "cef_log.txt"),
            atomically: false,
            encoding: .utf8
        )

        let recovered = reporter.detectSteamWebHelperStartup(
            in: steamDirectory,
            since: cursor
        )
        XCTAssertEqual(recovered.state, .provisionalSurface)
        XCTAssertTrue(recovered.hasPositiveRendererEvidence)
        XCTAssertNotNil(recovered.rendererAttemptIdentity)
        XCTAssertNil(recovered.reason)
        XCTAssertNil(reporter.detectSteamWebHelperRenderingFailure(
            in: steamDirectory,
            since: Date(timeIntervalSince1970: 0),
            logCursor: cursor
        ))

        let cefHandle = try FileHandle(
            forWritingTo: logs.appending(path: "cef_log.txt")
        )
        try cefHandle.seekToEnd()
        try cefHandle.write(contentsOf: Data(
            "[300:301:0814/103030.500:ERROR] ContextResult::kFatalFailure: Failed to create shared context\n".utf8
        ))
        try cefHandle.close()

        let currentFatal = reporter.detectSteamWebHelperStartup(
            in: steamDirectory,
            since: cursor
        )
        XCTAssertEqual(currentFatal.state, .retryableFailure)
        XCTAssertTrue(
            currentFatal.reason?.contains("shared graphics context") == true
        )
    }

    func testSteamWebHelperLatestAttemptAllowsFallbackSuccessUntilCurrentEpochExhausts() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlaySteamRendererEpoch-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let steamDirectory = temporaryRoot.appending(
            path: "Steam",
            directoryHint: .isDirectory
        )
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        for name in [
            "webhelper_gpu.txt",
            "steamui_html.txt",
            "steamui_login.txt",
            "console_log.txt",
            "webhelper.txt",
            "cef_log.txt",
            "shader_log.txt",
            "bootstrap_log.txt"
        ] {
            try Data().write(to: logs.appending(path: name))
        }

        let reporter = SteamLaunchDiagnosticsReporter()
        let cursor = reporter.captureSteamWebHelperStartupLogCursor(
            in: steamDirectory
        )
        try """
        [2026-08-14 10:30:20] Client version: 1750000000
        [2026-08-14 10:30:20] GPU process started: start count: 0
        [2026-08-14 10:30:20] eglInitialize D3D11 failed with error EGL_NOT_INITIALIZED
        [2026-08-14 10:30:20] eglInitialize D3D9 failed with error EGL_NOT_INITIALIZED
        [2026-08-14 10:30:20] Initialization of all EGL display types failed.
        [2026-08-14 10:30:20] Exiting GPU process due to errors during initialization
        [2026-08-14 10:30:30] Client version: 1750000001
        [2026-08-14 10:30:30] GPU process started: start count: 0
        [2026-08-14 10:30:30] eglInitialize D3D11 failed with error EGL_NOT_INITIALIZED, trying next display type
        [2026-08-14 10:30:30] eglInitialize D3D9 failed with error EGL_NOT_INITIALIZED, trying next display type
        [2026-08-14 10:30:30] GPU process started: start count: 1
        [2026-08-14 10:30:30] [ display type ]: angle_swangle
        [2026-08-14 10:30:30] [ gpu_compositing ]: enabled_on
        [2026-08-14 10:30:30] [ webgl ]: enabled
        """.write(
            to: logs.appending(path: "webhelper_gpu.txt"),
            atomically: false,
            encoding: .utf8
        )
        try """
        [2026-08-14 10:30:20] Startup - WebHelper launched pid: 100
        [2026-08-14 10:30:20] Triggering shutdown due to GPU process restarts
        [2026-08-14 10:30:30] Startup - WebHelper launched pid: 200
        [2026-08-14 10:30:30] SP DesktopLoginWindow_uid0-'Steam': WasHidden 0: (0, 0) 700x440
        """.write(
            to: logs.appending(path: "webhelper.txt"),
            atomically: false,
            encoding: .utf8
        )
        try "[2026-08-14 10:30:30] BrowserReady: handle:65536\n".write(
            to: logs.appending(path: "steamui_html.txt"),
            atomically: false,
            encoding: .utf8
        )
        try """
        [100:101:0814/103020.000:ERROR] ContextResult::kFatalFailure: Failed to create shared context
        [200:201:0814/103030.000:INFO] SwANGLE compositor initialized
        """.write(
            to: logs.appending(path: "cef_log.txt"),
            atomically: false,
            encoding: .utf8
        )

        let recovered = reporter.detectSteamWebHelperStartup(
            in: steamDirectory,
            since: cursor
        )
        XCTAssertEqual(recovered.state, .provisionalSurface)
        XCTAssertTrue(recovered.hasPositiveRendererEvidence)
        XCTAssertNotNil(recovered.rendererAttemptIdentity)
        XCTAssertNil(recovered.reason)
        XCTAssertFalse(
            recovered.webHelperGPUTail.contains {
                $0.contains("Client version: 1750000000")
            }
        )
        XCTAssertNil(reporter.detectSteamWebHelperRenderingFailure(
            in: steamDirectory,
            since: Date(timeIntervalSince1970: 0),
            logCursor: cursor
        ))

        let gpuLog = logs.appending(path: "webhelper_gpu.txt")
        let terminalHandle = try FileHandle(forWritingTo: gpuLog)
        try terminalHandle.seekToEnd()
        try terminalHandle.write(contentsOf: Data(
            "[2026-08-14 10:30:31] GPU process was unable to boot: GPU process crashed too many times\n".utf8
        ))
        try terminalHandle.close()

        let exhausted = reporter.detectSteamWebHelperStartup(
            in: steamDirectory,
            since: cursor
        )
        XCTAssertEqual(exhausted.state, .retryableFailure)
        XCTAssertTrue(
            exhausted.reason?.contains("GPU processes repeatedly failed") == true
        )
        XCTAssertNotNil(reporter.detectSteamWebHelperRenderingFailure(
            in: steamDirectory,
            since: Date(timeIntervalSince1970: 0),
            logCursor: cursor
        ))
    }

    func testSteamWebHelperActualDisabledCrashCountBlackWindowIsTerminalWithoutPositiveRendererEvidence() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlaySteamDisabledCrashCount-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let steamDirectory = temporaryRoot.appending(
            path: "Steam",
            directoryHint: .isDirectory
        )
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        for name in [
            "webhelper_gpu.txt",
            "steamui_html.txt",
            "steamui_login.txt",
            "console_log.txt",
            "webhelper.txt",
            "cef_log.txt",
            "shader_log.txt",
            "bootstrap_log.txt"
        ] {
            try Data().write(to: logs.appending(path: name))
        }

        let reporter = SteamLaunchDiagnosticsReporter()
        let cursor = reporter.captureSteamWebHelperStartupLogCursor(
            in: steamDirectory
        )
        try """
        [2026-08-14 10:30:29] Client version: 1750000001
        [2026-08-14 10:30:29] GPU process started: start count: 0
        [2026-08-14 10:30:30] GPU process started: start count: 1
        [2026-08-14 10:30:31] GPU process started: start count: 2
        [2026-08-14 10:30:32] GPU process started: start count: 3
        """.write(
            to: logs.appending(path: "webhelper_gpu.txt"),
            atomically: false,
            encoding: .utf8
        )
        try """
        [2026-08-14 10:30:29] Startup - WebHelper launched pid: 300
        [2026-08-14 10:30:34] SP DesktopLoginWindow_uid0-'Steam': WasHidden 0: (0, 0) 700x440
        """.write(
            to: logs.appending(path: "webhelper.txt"),
            atomically: false,
            encoding: .utf8
        )

        let restarting = reporter.detectSteamWebHelperStartup(
            in: steamDirectory,
            since: cursor
        )
        XCTAssertEqual(restarting.state, .provisionalSurface)
        XCTAssertFalse(
            restarting.hasPositiveRendererEvidence,
            "GPU child creation is lifecycle evidence, not proof of a usable renderer"
        )
        XCTAssertNil(restarting.rendererAttemptIdentity)
        XCTAssertNil(reporter.detectSteamWebHelperRenderingFailure(
            in: steamDirectory,
            since: Date(timeIntervalSince1970: 0),
            logCursor: cursor
        ))

        let gpuLog = logs.appending(path: "webhelper_gpu.txt")
        let terminalHandle = try FileHandle(forWritingTo: gpuLog)
        try terminalHandle.seekToEnd()
        try terminalHandle.write(contentsOf: Data(
            "[2026-08-14 10:30:33] Disabling GPU acceleration: Disabled/CrashCount\n".utf8
        ))
        try terminalHandle.close()

        let observation = reporter.detectSteamWebHelperStartup(
            in: steamDirectory,
            since: cursor
        )
        XCTAssertEqual(observation.state, .retryableFailure)
        XCTAssertEqual(observation.provisionalSurfaceReadiness, .loginWindow)
        XCTAssertFalse(observation.hasPositiveRendererEvidence)
        XCTAssertTrue(
            observation.reason?.contains("GPU processes repeatedly failed") == true
        )
        XCTAssertNotNil(reporter.detectSteamWebHelperRenderingFailure(
            in: steamDirectory,
            since: Date(timeIntervalSince1970: 0),
            logCursor: cursor
        ))
    }

    func testSteamWebHelperStartupRequiresUsableSurfaceAndFatalCEFOverridesBrowserReady() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamUsableUIRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let steamDirectory = temporaryRoot.appending(path: "Steam", directoryHint: .isDirectory)
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let html = logs.appending(path: "steamui_html.txt")
        let webHelper = logs.appending(path: "webhelper.txt")
        let cefLog = logs.appending(path: "cef_log.txt")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        for url in [html, webHelper, cefLog] {
            try Data().write(to: url)
        }

        let reporter = SteamLaunchDiagnosticsReporter()
        let cursor = reporter.captureSteamWebHelperStartupLogCursor(in: steamDirectory)
        let htmlHandle = try FileHandle(forWritingTo: html)
        try htmlHandle.seekToEnd()
        try htmlHandle.write(contentsOf: Data("BrowserReady: handle:65536\n".utf8))
        try htmlHandle.close()

        let sharedContextOnly = reporter.detectSteamWebHelperStartup(
            in: steamDirectory,
            since: cursor
        )
        XCTAssertEqual(sharedContextOnly.state, .pending)
        XCTAssertEqual(sharedContextOnly.sharedContextReadiness, .ready)
        XCTAssertEqual(sharedContextOnly.usableUIReadiness, .pending)

        let webHelperHandle = try FileHandle(forWritingTo: webHelper)
        try webHelperHandle.seekToEnd()
        try webHelperHandle.write(contentsOf: Data(
            "SP DesktopLoginWindow_uid0-'Steam': WasHidden 0: (0, 0) 700x440\n".utf8
        ))
        try webHelperHandle.close()
        let cefLogHandle = try FileHandle(forWritingTo: cefLog)
        try cefLogHandle.seekToEnd()
        try cefLogHandle.write(contentsOf: Data(
            "ContextResult::kFatalFailure: Failed to create shared context for virtualization\n".utf8
        ))
        try cefLogHandle.close()

        let fatal = reporter.detectSteamWebHelperStartup(
            in: steamDirectory,
            since: cursor
        )
        XCTAssertEqual(fatal.state, .retryableFailure)
        XCTAssertEqual(fatal.sharedContextReadiness, .ready)
        XCTAssertEqual(fatal.provisionalSurfaceReadiness, .loginWindow)
        XCTAssertEqual(fatal.usableUIReadiness, .pending)
        XCTAssertTrue(fatal.reason?.contains("shared graphics context") == true)

        let unresponsiveCursor = reporter.captureSteamWebHelperStartupLogCursor(
            in: steamDirectory
        )
        let unresponsiveHandle = try FileHandle(forWritingTo: webHelper)
        try unresponsiveHandle.seekToEnd()
        try unresponsiveHandle.write(contentsOf: Data(
            "Killing unresponsive browser for user-visible Steam window\n".utf8
        ))
        try unresponsiveHandle.close()
        let unresponsive = reporter.detectSteamWebHelperStartup(
            in: steamDirectory,
            since: unresponsiveCursor
        )
        XCTAssertEqual(unresponsive.state, .retryableFailure)
        XCTAssertEqual(
            unresponsive.reason,
            "Steam WebHelper killed an unresponsive browser before a usable Steam UI appeared"
        )
    }

    func testSteamWebHelperStartupRejectsAlternateSharedContextFatalSignatures() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlaySteamAlternateCEFFatal-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let steamDirectory = temporaryRoot.appending(
            path: "Steam",
            directoryHint: .isDirectory
        )
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let cefLog = logs.appending(path: "cef_log.txt")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        for name in ["steamui_html.txt", "console_log.txt", "webhelper.txt"] {
            try Data().write(to: logs.appending(path: name))
        }
        try Data().write(to: cefLog)

        let reporter = SteamLaunchDiagnosticsReporter()
        let cursor = reporter.captureSteamWebHelperStartupLogCursor(
            in: steamDirectory
        )
        let handle = try FileHandle(forWritingTo: cefLog)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            """
            SharedImageStub: unable to create context
            Failed to create GLES3 context, fallback to GLES2.
            Failed to create GLES2 context.
            """.utf8
        ))
        try handle.close()

        let observation = reporter.detectSteamWebHelperStartup(
            in: steamDirectory,
            since: cursor
        )

        XCTAssertEqual(observation.state, .retryableFailure)
        XCTAssertTrue(
            observation.reason?.contains("shared graphics context") == true
        )
    }

    func testCapturedTerminalCEFFailureOutranksUnrelatedUnavailableStartupLog() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlaySteamCEFFatalPriority-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let steamDirectory = temporaryRoot.appending(
            path: "Steam",
            directoryHint: .isDirectory
        )
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let console = logs.appending(path: "console_log.txt")
        let consoleHardlink = logs.appending(path: "console-hardlink.txt")
        let cefLog = logs.appending(path: "cef_log.txt")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        for name in ["steamui_html.txt", "webhelper.txt"] {
            try Data().write(to: logs.appending(path: name))
        }
        try Data().write(to: console)
        try FileManager.default.linkItem(at: console, to: consoleHardlink)
        try Data().write(to: cefLog)

        let reporter = SteamLaunchDiagnosticsReporter()
        let cursor = reporter.captureSteamWebHelperStartupLogCursor(
            in: steamDirectory
        )
        XCTAssertEqual(cursor.console.captureState, .unsafe)
        let cefLogHandle = try FileHandle(forWritingTo: cefLog)
        try cefLogHandle.seekToEnd()
        try cefLogHandle.write(contentsOf: Data(
            "ContextResult::kFatalFailure: Failed to create shared context\n".utf8
        ))
        try cefLogHandle.close()

        let observation = reporter.detectSteamWebHelperStartup(
            in: steamDirectory,
            since: cursor
        )

        XCTAssertEqual(observation.state, .retryableFailure)
        XCTAssertTrue(
            observation.reason?.contains("shared graphics context") == true
        )
        XCTAssertTrue(
            observation.consoleTail.contains {
                $0.contains("evidence state=unsafe")
            }
        )
    }

    func testSteamWebHelperStartupCursorFailureDoesNotAttributeHistoricalUntimestampedLinesToLaunch() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamUnsafeStartupCursor-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let steamDirectory = temporaryRoot.appending(path: "Steam", directoryHint: .isDirectory)
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let html = logs.appending(path: "steamui_html.txt")
        let hardlink = logs.appending(path: "steamui_html-hardlink.txt")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "Timed out waiting for webhelper init\n".write(to: html, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: html, to: hardlink)
        try Data().write(to: logs.appending(path: "console_log.txt"))
        try Data().write(to: logs.appending(path: "webhelper.txt"))

        let reporter = SteamLaunchDiagnosticsReporter()
        let cursor = reporter.captureSteamWebHelperStartupLogCursor(in: steamDirectory)
        XCTAssertEqual(cursor.steamUIHTML.captureState, .unsafe)

        try FileManager.default.removeItem(at: html)
        try "Timed out waiting for webhelper init\n".write(to: html, atomically: true, encoding: .utf8)
        let observation = reporter.detectSteamWebHelperStartup(in: steamDirectory, since: cursor)

        XCTAssertEqual(observation.state, .evidenceUnavailable)
        XCTAssertTrue(observation.shouldRetry)
        XCTAssertTrue(observation.reason?.contains("baseline cursor was unsafe") == true, observation.reason ?? "")
        XCTAssertFalse(
            observation.steamUIHTMLTail.contains(where: { $0 == "Timed out waiting for webhelper init" }),
            observation.steamUIHTMLTail.joined(separator: "\n")
        )
        XCTAssertTrue(
            observation.steamUIHTMLTail.contains(where: { $0.contains("evidence state=unsafe") }),
            observation.steamUIHTMLTail.joined(separator: "\n")
        )
    }

    func testSteamLaunchDiagnosticsWriteFailureThrowsAndProducesExplicitFallbackArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamDiagnosticsFailure-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        let stdout = logs.appending(path: "steam_launch_stdout.log")
        let stderr = logs.appending(path: "steam_launch_stderr.log")
        try "stdout evidence".write(to: stdout, atomically: true, encoding: .utf8)
        try "stderr evidence".write(to: stderr, atomically: true, encoding: .utf8)
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: root.appending(path: "wine"),
            arguments: ["steam.exe"],
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 102),
            exitCode: 9,
            stdoutLog: stdout,
            stderrLog: stderr,
            didTimeOut: false,
            waitedForExit: true,
            outcome: .signaled,
            terminationSignal: 9
        )
        let diagnosticURL = stderr
            .deletingPathExtension()
            .appendingPathExtension("diagnostics.log")
        let evidenceDirectory = diagnosticURL
            .deletingPathExtension()
            .appendingPathExtension("diagnostics")
        try Data("blocks evidence directory creation".utf8).write(to: evidenceDirectory)
        let reporter = SteamLaunchDiagnosticsReporter()

        var capturedError: Error?
        XCTAssertThrowsError(try reporter.writeDiagnostics(
            for: result,
            preflightShutdown: nil,
            failureShutdown: nil,
            failureShutdownError: nil,
            dumps: [],
            steamDirectory: steamDirectory,
            renderingIssue: nil,
            launchEnvironmentSummary: [],
            since: Date(timeIntervalSince1970: 0)
        )) { error in
            capturedError = error
        }
        let failure = try XCTUnwrap(capturedError)
        let fallbackURL = try reporter.writeDiagnosticsFailureFallback(for: result, error: failure)
        let fallback = try String(contentsOf: fallbackURL, encoding: .utf8)

        XCTAssertEqual(fallbackURL.standardizedFileURL.path, diagnosticURL.standardizedFileURL.path)
        XCTAssertTrue(fallback.contains("ForgePlay Steam diagnostics capture failure"), fallback)
        XCTAssertTrue(fallback.contains("Action: launchSteam"), fallback)
        XCTAssertTrue(fallback.contains("Outcome: signaled"), fallback)
        XCTAssertTrue(fallback.contains("Termination signal: 9"), fallback)
        XCTAssertTrue(fallback.contains("Capture error:"), fallback)
        XCTAssertTrue(fallback.contains("full diagnostics report is incomplete"), fallback.lowercased())
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidenceDirectory.appending(path: "manifest.json").path))
        let assessment = try XCTUnwrap(reporter.evidenceAssessment(for: fallbackURL))
        XCTAssertEqual(assessment.completeness, .incomplete)
        XCTAssertFalse(assessment.isCompleteEnoughForHardGateSuccess)
        XCTAssertTrue(assessment.diagnosticCaptureWarning?.contains("full diagnostics capture failed") == true)
    }

    func testSteamDiagnosticsDoNotPresentSyntheticCompatibilityExitCodeAsProcessStatus() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySyntheticExitDiagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        let runLogs = root.appending(path: "RunLogs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runLogs, withIntermediateDirectories: true)
        let stdout = runLogs.appending(path: "synthetic_stdout.log")
        let stderr = runLogs.appending(path: "synthetic_stderr.log")
        try Data("preflight did not start a process\n".utf8).write(to: stdout)
        try Data("spawn failed\n".utf8).write(to: stderr)
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: root.appending(path: "missing-wine"),
            arguments: ["steam.exe"],
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            exitCode: 1,
            hasProcessExitCode: false,
            stdoutLog: stdout,
            stderrLog: stderr,
            didTimeOut: false,
            waitedForExit: false,
            outcome: .spawnFailed
        )

        XCTAssertNil(result.processExitCode)
        let reporter = SteamLaunchDiagnosticsReporter()
        let diagnosticURL = try reporter.writeDiagnostics(
            for: result,
            preflightShutdown: nil,
            failureShutdown: nil,
            failureShutdownError: nil,
            dumps: [],
            steamDirectory: steamDirectory,
            renderingIssue: nil,
            gateStatus: .blocked,
            launchEnvironmentSummary: [],
            since: Date(timeIntervalSince1970: 0)
        )
        let diagnostics = try String(contentsOf: diagnosticURL, encoding: .utf8)
        let evidenceIndex = try String(
            contentsOf: diagnosticURL
                .deletingPathExtension()
                .appendingPathExtension("diagnostics")
                .appending(path: "index.md"),
            encoding: .utf8
        )

        XCTAssertTrue(
            diagnostics.contains("Process exit code: unavailable (the process did not produce an exit status)"),
            diagnostics
        )
        XCTAssertTrue(
            evidenceIndex.contains("- process exit code: unavailable (the process did not produce an exit status)"),
            evidenceIndex
        )
        XCTAssertFalse(diagnostics.contains("Process exit code: 1\n"), diagnostics)
    }

    func testCorruptMinidumpWithUnboundedStreamCountIsRejectedWithoutLooping() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCorruptMinidump-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dump = root.appending(path: "corrupt.dmp")
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes.replaceSubrange(0..<4, with: Array("MDMP".utf8))
        bytes[8] = 0xFF
        bytes[9] = 0xFF
        bytes[10] = 0xFF
        bytes[11] = 0xFF
        try Data(bytes).write(to: dump)

        let startedAt = Date()
        XCTAssertFalse(SteamLaunchDiagnosticsReporter().crashDumpIndicatesAccessViolation(dump))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testSteamDiagnosticsRejectsUnsafeLogSourceAndDowngradesReportedSuccess() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayUnsafeSteamLogEvidence-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        let steamLogs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let runLogs = root.appending(path: "RunLogs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runLogs, withIntermediateDirectories: true)
        let linkedTarget = root.appending(path: "untrusted-webhelper.log")
        try "No available renderers from an unsafe source\n".write(
            to: linkedTarget,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: steamLogs.appending(path: "webhelper_gpu.txt"),
            withDestinationURL: linkedTarget
        )
        let stdout = runLogs.appending(path: "steam_stdout.log")
        let stderr = runLogs.appending(path: "steam_stderr.log")
        try Data("stdout\n".utf8).write(to: stdout)
        try Data("stderr\n".utf8).write(to: stderr)
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: root.appending(path: "wine"),
            arguments: ["steam.exe"],
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            exitCode: 0,
            stdoutLog: stdout,
            stderrLog: stderr,
            didTimeOut: false,
            waitedForExit: false
        )

        let reporter = SteamLaunchDiagnosticsReporter()
        let diagnosticURL = try reporter.writeDiagnostics(
            for: result,
            preflightShutdown: nil,
            failureShutdown: nil,
            failureShutdownError: nil,
            dumps: [],
            steamDirectory: steamDirectory,
            renderingIssue: nil,
            gateStatus: .success,
            launchEnvironmentSummary: [],
            since: Date(timeIntervalSince1970: 0)
        )
        let diagnostics = try String(contentsOf: diagnosticURL, encoding: .utf8)
        let evidenceIndex = try String(
            contentsOf: diagnosticURL
                .deletingPathExtension()
                .appendingPathExtension("diagnostics")
                .appending(path: "index.md"),
            encoding: .utf8
        )

        XCTAssertTrue(diagnostics.contains("- Status: FAILED"), diagnostics)
        XCTAssertTrue(diagnostics.contains("webhelper_gpu.txt: unsafe"), diagnostics)
        XCTAssertTrue(diagnostics.contains("Diagnostic evidence inspection was incomplete"), diagnostics)
        XCTAssertTrue(diagnostics.contains("evidence state=unsafe"), diagnostics)
        XCTAssertFalse(diagnostics.contains("No available renderers from an unsafe source"), diagnostics)
        XCTAssertFalse(diagnostics.contains("No known ForgePlay runtime pattern was detected"), diagnostics)
        XCTAssertTrue(evidenceIndex.contains("Status: FAILED"), evidenceIndex)
        let assessment = try XCTUnwrap(reporter.evidenceAssessment(for: diagnosticURL))
        XCTAssertFalse(assessment.isCompleteEnoughForHardGateSuccess)
        XCTAssertEqual(assessment.completeness, .incomplete)
        XCTAssertEqual(assessment.requestedGateStatus, .success)
        XCTAssertEqual(assessment.reportedGateStatus, .failed)
        XCTAssertTrue(assessment.diagnosticCaptureWarning?.contains("webhelper_gpu.txt") == true)
    }

    func testSteamLogCursorRejectsIntermediateLogDirectorySymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayUnsafeSteamLogParent-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        let redirectedLogs = root.appending(path: "RedirectedLogs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: redirectedLogs, withIntermediateDirectories: true)
        try "Starting message loop\n".write(
            to: redirectedLogs.appending(path: "webhelper.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: steamDirectory.appending(path: "logs", directoryHint: .isDirectory),
            withDestinationURL: redirectedLogs
        )

        let cursor = SteamLaunchDiagnosticsReporter()
            .captureSteamWebHelperStartupLogCursor(in: steamDirectory)

        XCTAssertEqual(cursor.webHelper.captureState, .unsafe)
        XCTAssertTrue(cursor.webHelper.captureDetail?.contains("secure directory component open failed") == true)
        XCTAssertEqual(cursor.webHelperGPU.captureState, .unsafe)
        XCTAssertEqual(cursor.steamUIHTML.captureState, .unsafe)
    }

    func testSteamDiagnosticsDistinguishesUnsafeCrashDumpScanFromNoDumps() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayUnsafeSteamDumpEvidence-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let dumpsDirectory = root.appending(path: "Steam/dumps", directoryHint: .isDirectory)
        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        let runLogs = root.appending(path: "RunLogs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dumpsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runLogs, withIntermediateDirectories: true)
        let dump = dumpsDirectory.appending(path: "crash_steam_test.dmp")
        let dumpHardlink = root.appending(path: "crash_steam_test-hardlink.dmp")
        try Data("MDMP".utf8).write(to: dump)
        try FileManager.default.linkItem(at: dump, to: dumpHardlink)

        let reporter = SteamLaunchDiagnosticsReporter()
        let crashDumpObservationContext = reporter.beginCrashDumpObservationContext()
        defer { reporter.discardCrashDumpObservationContext(crashDumpObservationContext) }
        XCTAssertTrue(
            reporter.recentSteamCrashDumps(
                in: dumpsDirectory,
                since: Date(timeIntervalSince1970: 0),
                observationContext: crashDumpObservationContext
            ).isEmpty
        )
        let stdout = runLogs.appending(path: "steam_stdout.log")
        let stderr = runLogs.appending(path: "steam_stderr.log")
        try Data("stdout\n".utf8).write(to: stdout)
        try Data("stderr\n".utf8).write(to: stderr)
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: root.appending(path: "wine"),
            arguments: ["steam.exe"],
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            exitCode: 0,
            stdoutLog: stdout,
            stderrLog: stderr,
            didTimeOut: false,
            waitedForExit: false
        )
        let diagnosticURL = try reporter.writeDiagnostics(
            for: result,
            preflightShutdown: nil,
            failureShutdown: nil,
            failureShutdownError: nil,
            dumps: [],
            steamDirectory: steamDirectory,
            renderingIssue: nil,
            gateStatus: .success,
            launchEnvironmentSummary: [],
            crashDumpObservationContext: crashDumpObservationContext,
            since: Date(timeIntervalSince1970: 0)
        )
        let diagnostics = try String(contentsOf: diagnosticURL, encoding: .utf8)

        XCTAssertTrue(diagnostics.contains("- Status: FAILED"), diagnostics)
        XCTAssertTrue(diagnostics.contains("crash dump scan unsafe"), diagnostics)
        XCTAssertTrue(diagnostics.contains("none confirmed; crash dump inspection was incomplete"), diagnostics)
        XCTAssertFalse(diagnostics.contains("Steam crash dumps: none detected after this launch"), diagnostics)
        let assessment = try XCTUnwrap(reporter.evidenceAssessment(for: diagnosticURL))
        XCTAssertFalse(assessment.isCompleteEnoughForHardGateSuccess)
        XCTAssertTrue(assessment.diagnosticCaptureWarning?.contains("crash dump scan unsafe") == true)
    }

    func testSteamCrashDumpObservationsDoNotLeakAcrossLaunchContexts() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamDumpContextIsolation-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let launchASteam = root.appending(path: "LaunchA/Steam", directoryHint: .isDirectory)
        let launchADumps = launchASteam.appending(path: "dumps", directoryHint: .isDirectory)
        let launchBSteam = root.appending(path: "LaunchB/Steam", directoryHint: .isDirectory)
        let launchBDumps = launchBSteam.appending(path: "dumps", directoryHint: .isDirectory)
        let runLogs = root.appending(path: "LaunchB/RunLogs", directoryHint: .isDirectory)
        for directory in [launchADumps, launchBDumps, runLogs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let unsafeDump = launchADumps.appending(path: "crash_context_a.dmp")
        try Data("MDMP".utf8).write(to: unsafeDump)
        try FileManager.default.linkItem(
            at: unsafeDump,
            to: root.appending(path: "crash_context_a-hardlink.dmp")
        )

        let reporter = SteamLaunchDiagnosticsReporter()
        let contextA = reporter.beginCrashDumpObservationContext()
        let contextB = reporter.beginCrashDumpObservationContext()
        defer {
            reporter.discardCrashDumpObservationContext(contextA)
            reporter.discardCrashDumpObservationContext(contextB)
        }
        _ = reporter.recentSteamCrashDumpScan(
            in: launchADumps,
            since: .distantPast,
            observationContext: contextA
        )
        _ = reporter.recentSteamCrashDumpScan(
            in: launchBDumps,
            since: .distantPast,
            observationContext: contextB
        )

        let stdout = runLogs.appending(path: "steam_stdout.log")
        let stderr = runLogs.appending(path: "steam_stderr.log")
        try Data("stdout\n".utf8).write(to: stdout)
        try Data("stderr\n".utf8).write(to: stderr)
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: root.appending(path: "wine"),
            arguments: ["steam.exe"],
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            exitCode: 0,
            stdoutLog: stdout,
            stderrLog: stderr,
            didTimeOut: false,
            waitedForExit: false
        )
        let diagnosticURL = try reporter.writeDiagnostics(
            for: result,
            preflightShutdown: nil,
            failureShutdown: nil,
            failureShutdownError: nil,
            dumps: [],
            steamDirectory: launchBSteam,
            renderingIssue: nil,
            gateStatus: .success,
            launchEnvironmentSummary: [],
            crashDumpObservationContext: contextB,
            since: .distantPast
        )
        let diagnostics = try String(contentsOf: diagnosticURL, encoding: .utf8)

        XCTAssertTrue(diagnostics.contains("\(launchBDumps.path): captured"), diagnostics)
        XCTAssertFalse(diagnostics.contains(launchADumps.path), diagnostics)
        XCTAssertFalse(diagnostics.contains("crash dump scan unsafe"), diagnostics)
        XCTAssertEqual(reporter.evidenceAssessment(for: diagnosticURL)?.reportedGateStatus, .success)
    }

    func testCrashDumpScanRejectsNestedSymlinkDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayUnsafeNestedDumpDirectory-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let dumpsDirectory = root.appending(path: "Steam/dumps", directoryHint: .isDirectory)
        let redirectedDirectory = root.appending(path: "RedirectedDumps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dumpsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: redirectedDirectory, withIntermediateDirectories: true)
        try Data("MDMP".utf8).write(
            to: redirectedDirectory.appending(path: "crash_untrusted.dmp")
        )
        try FileManager.default.createSymbolicLink(
            at: dumpsDirectory.appending(path: "nested", directoryHint: .isDirectory),
            withDestinationURL: redirectedDirectory
        )

        let scan = SteamLaunchDiagnosticsReporter().recentSteamCrashDumpScan(
            in: dumpsDirectory,
            since: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(scan.state, .unsafe)
        XCTAssertTrue(scan.urls.isEmpty)
        XCTAssertTrue(scan.detail.contains("symbolic-link item rejected"), scan.detail)
    }

    func testSteamDiagnosticsMarksLargeLogTailAsTruncatedWhileRetainingNewestEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayBoundedSteamLogEvidence-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        let steamLogs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let runLogs = root.appending(path: "RunLogs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runLogs, withIntermediateDirectories: true)
        var oversizedLog = Data(repeating: Character("x").asciiValue!, count: 600 * 1024)
        oversizedLog.append(Data("\n[2026-07-16 00:00:00] newest bounded evidence\n".utf8))
        try oversizedLog.write(to: steamLogs.appending(path: "webhelper_gpu.txt"))
        let stdout = runLogs.appending(path: "steam_stdout.log")
        let stderr = runLogs.appending(path: "steam_stderr.log")
        try Data("stdout\n".utf8).write(to: stdout)
        try Data("stderr\n".utf8).write(to: stderr)
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: root.appending(path: "wine"),
            arguments: ["steam.exe"],
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            exitCode: 0,
            stdoutLog: stdout,
            stderrLog: stderr,
            didTimeOut: false,
            waitedForExit: false
        )

        let reporter = SteamLaunchDiagnosticsReporter()
        let diagnosticURL = try reporter.writeDiagnostics(
            for: result,
            preflightShutdown: nil,
            failureShutdown: nil,
            failureShutdownError: nil,
            dumps: [],
            steamDirectory: steamDirectory,
            renderingIssue: nil,
            gateStatus: .launched,
            launchEnvironmentSummary: [],
            since: Date(timeIntervalSince1970: 0)
        )
        let diagnostics = try String(contentsOf: diagnosticURL, encoding: .utf8)

        XCTAssertTrue(diagnostics.contains("webhelper_gpu.txt: truncated"), diagnostics)
        XCTAssertTrue(diagnostics.contains("evidence state=truncated"), diagnostics)
        XCTAssertTrue(diagnostics.contains("newest bounded evidence"), diagnostics)
        XCTAssertFalse(diagnostics.contains(String(repeating: "x", count: 1_024)), diagnostics)
        XCTAssertTrue(
            try XCTUnwrap(reporter.evidenceAssessment(for: diagnosticURL))
                .isCompleteEnoughForHardGateSuccess
        )
    }

    func testOperationalUITimeoutDoesNotRestartOrStopSessionOrTransferFreshLanguage() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayDelayedOperationalEvidenceRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let cefDirectory = steamDirectory.appending(path: "bin/cef/cef.win7x64", directoryHint: .isDirectory)
        let runtimeRoot = temporaryRoot.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcherDirectory = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        let invocationLog = temporaryRoot.appending(path: "delayed-operational-evidence-invocations.log")
        let liveWebHelperMarker = temporaryRoot.appending(
            path: "delayed-operational-webhelper-live.marker"
        )
        let webHelperProcessID: Int32 = 70_002
        let webHelperProcessStartedAtUnixMicroseconds: UInt64 = 970_002
        let webHelperCommand =
            #"C:\Program Files (x86)\Steam\bin\cef\cef.win7x64\steamwebhelper.exe --no-sandbox"#

        try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cefDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("valve webhelper".utf8).write(to: cefDirectory.appending(path: "steamwebhelper.exe"))
        try Data("cef runtime".utf8).write(to: cefDirectory.appending(path: "libcef.dll"))
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        if [ "$1" = "--version" ]; then
          printf 'wine-11.12\\n'
          exit 0
        fi
        if [ "$1" = "wineserver" ]; then
          exit 0
        fi
        if [ "$2" = "-shutdown" ]; then
          exit 0
        fi
        observation_path="${FORGEPLAY_PROCESS_OBSERVATION_FILE#Z:}"
        observation_path="$(printf '%s' "$observation_path" | tr '\\' '/')"
        (
          sleep 0.3
          printf '%s\t%s\t%s\n' \
            'FORGEPLAY_PROCESS_V1' \
            '\(webHelperProcessID)' \
            '\(webHelperCommand)' \
            >> "$observation_path"
          printf 'live\n' > "\(liveWebHelperMarker.path)"
        ) &
        sleep 1
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let languagePolicy = SteamClientLanguageOwnershipPolicy(
            runner: makeCuratedRuntimeRunner()
        )
        let languageClaim = try await languagePolicy.claimFreshInstallation(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: temporaryRoot,
            language: .koreana
        )
        XCTAssertNotNil(languageClaim)
        try Data("steam".utf8).write(
            to: steamDirectory.appending(path: "steam.exe")
        )

        let steamManager = makeSteamManager(
            pathManager: pathManager,
            processEvidenceTimeout: 0.2,
            processEvidencePollInterval: 0.1,
            processSnapshotProvider: {
                guard FileManager.default.fileExists(
                    atPath: liveWebHelperMarker.path
                ) else {
                    return SteamLaunchProcessSnapshot(processes: [])
                }
                return SteamLaunchProcessSnapshot(processes: [
                    SteamLaunchObservedProcess(
                        processID: webHelperProcessID,
                        command: webHelperCommand,
                        processStartedAtUnixMicroseconds:
                            webHelperProcessStartedAtUnixMicroseconds
                    )
                ])
            },
            managedWineLaunchProcessIdentityProvider: { _, _ in
                guard FileManager.default.fileExists(
                    atPath: liveWebHelperMarker.path
                ) else {
                    return []
                }
                return [
                    ManagedWineLaunchProcessIdentity(
                        processID: webHelperProcessID,
                        processStartedAtUnixMicroseconds:
                            webHelperProcessStartedAtUnixMicroseconds,
                        executableURL: launcher
                    )
                ]
            },
            managedWineJournalProcessSnapshotProvider: { identities in
                guard FileManager.default.fileExists(
                    atPath: liveWebHelperMarker.path
                ) else {
                    return SteamLaunchProcessSnapshot(processes: [])
                }
                return SteamLaunchProcessSnapshot(processes: identities.map {
                    identity in
                    SteamLaunchObservedProcess(
                        processID: identity.processID,
                        command: webHelperCommand,
                        evidenceSource: .managedWineJournal,
                        processStartedAtUnixMicroseconds:
                            identity.processStartedAtUnixMicroseconds
                    )
                })
            }
        )
        try await applySteamLaunchPolicy(steamManager: steamManager, prefix: prefix, launcher: launcher)
        try? FileManager.default.removeItem(at: invocationLog)

        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .operational,
            rendererPolicy: .d3dMetal
        )
        let invocations = try String(
            contentsOf: invocationLog,
            encoding: .utf8
        ).split(whereSeparator: \.isNewline).map(String.init)

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.waitedForExit)
        XCTAssertEqual(result.processExitCode, 0)
        XCTAssertNil(result.forgePlayStatusCode)
        XCTAssertEqual(result.steamUIVerificationState, .launchedButUnverified)
        XCTAssertEqual(result.steamUIStartupRecoveryAttemptCount, 0)
        XCTAssertNil(result.steamUIStartupRecoveryReason)
        let steamLaunchInvocations = invocations.filter {
            $0.contains("C:\\Program Files (x86)\\Steam\\steam.exe") &&
                !$0.contains("-shutdown")
        }
        XCTAssertEqual(
            steamLaunchInvocations.count,
            1,
            "a UI observation timeout must not synthesize a second Steam launch"
        )
        XCTAssertNotNil(result.diagnosticLog)
        let diagnostics = try String(contentsOf: try XCTUnwrap(result.diagnosticLog), encoding: .utf8)
        XCTAssertTrue(diagnostics.contains("Status: LAUNCHED"), diagnostics)
        XCTAssertFalse(diagnostics.contains("operational-process-evidence-unavailable"), diagnostics)
        XCTAssertFalse(diagnostics.contains("Post-failure Steam Prefix process shutdown:"), diagnostics)
        let steamLaunchIndex = try XCTUnwrap(
            invocations.firstIndex {
                $0.contains("C:\\Program Files (x86)\\Steam\\steam.exe") &&
                    !$0.contains("-shutdown")
            }
        )
        XCTAssertTrue(
            invocations.prefix(upTo: steamLaunchIndex)
                .contains("wineserver --kill=\(SIGTERM)"),
            "the explicit preflight cleanup must still precede the user launch"
        )
        XCTAssertFalse(
            invocations.dropFirst(steamLaunchIndex + 1)
                .contains("wineserver --kill=\(SIGTERM)"),
            invocations.joined(separator: "\n")
        )
        XCTAssertTrue(
            invocations.contains {
                $0.contains("steam.exe") && $0.contains("-language koreana")
            }
        )

        // A successful launch and observed WebHelper process are not the first
        // UI boundary. Simulate an updater rewrite after the accepted launch;
        // without a fresh usable Steam surface the pending lease must reproject
        // instead of relinquishing the marker as if the user changed Steam.
        try #"""
        WINE REGISTRY Version 2

        [Software\\Valve\\Steam]
        "Language"="english"
        """#.write(
            to: prefix.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
        let resumedLanguageLease = try await languagePolicy.prepareForLaunch(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: temporaryRoot
        )
        XCTAssertEqual(resumedLanguageLease?.language, .koreana)
        XCTAssertEqual(
            try languagePolicy.observedRegistryLanguageToken(in: prefix),
            "koreana"
        )
        XCTAssertTrue(try languagePolicy.hasOwnershipMarker(in: prefix))
    }

    func testBootstrapProgressDetectionIgnoresNormalStartupAndStaleUpdateLogs() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamBootstrapLogRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let steamDirectory = temporaryRoot.appending(path: "Steam", directoryHint: .isDirectory)
        let logDirectory = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let stdout = temporaryRoot.appending(path: "steam-launch-stdout.log")
        let stderr = temporaryRoot.appending(path: "steam-launch-stderr.log")
        let bootstrapLog = logDirectory.appending(path: "bootstrap_log.txt")
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try Data().write(to: stdout)
        try Data().write(to: stderr)
        try "Downloading update (stale/previous-launch)\n".write(
            to: bootstrapLog,
            atomically: true,
            encoding: .utf8
        )
        let startedAt = Date()
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: temporaryRoot.appending(path: "wine"),
            arguments: [],
            startedAt: startedAt,
            endedAt: startedAt,
            exitCode: 0,
            stdoutLog: stdout,
            stderrLog: stderr,
            didTimeOut: false,
            waitedForExit: false
        )
        let launchLogCursor = SteamLaunchDiagnosticsReporter()
            .captureSteamWebHelperStartupLogCursor(in: steamDirectory)
        let updateCursor = steamManager.bootstrapUpdateSourceCursor(
            from: launchLogCursor
        )
        var updaterTracker = SteamBootstrapUpdaterEvidenceTracker(
            cursor: updateCursor
        )

        let bootstrapHandle = try FileHandle(forWritingTo: bootstrapLog)
        defer { try? bootstrapHandle.close() }
        try bootstrapHandle.seekToEnd()
        try bootstrapHandle.write(contentsOf: Data("""
        Startup - updater built Jun 24 2026
        Startup - Steam Client launched with: steam.exe
        Suppressing Steam update
        """.utf8))
        let normalStartup = steamManager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: updateCursor
        )
        XCTAssertFalse(normalStartup.hasProgress == true)
        XCTAssertEqual(
            updaterTracker.observe(
                assessment: normalStartup,
                at: startedAt,
                idleTimeout: 10
            ).state,
            .notInProgress
        )
        let normalCursor = try XCTUnwrap(normalStartup.nextCursor)

        try bootstrapHandle.write(contentsOf: Data(
            "\nVerification complete\n업데이트 다운로드 중...(10,000/100,000KB)\n".utf8
        ))
        let firstProgress = steamManager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: normalCursor
        )
        XCTAssertEqual(firstProgress.hasProgress, true)
        XCTAssertTrue(firstProgress.observedProgress)
        XCTAssertFalse(firstProgress.observedCompletion)
        XCTAssertEqual(
            updaterTracker.observe(
                assessment: firstProgress,
                at: startedAt.addingTimeInterval(1),
                idleTimeout: 10
            ).state,
            .inProgress
        )
        let firstProgressIdentity = try XCTUnwrap(
            firstProgress.progressIdentity
        )

        let firstProgressCursor = try XCTUnwrap(firstProgress.nextCursor)
        try bootstrapHandle.write(contentsOf: Data(
            "Downloading update (20,000/100,000KB)\n".utf8
        ))
        let advancingProgress = steamManager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: firstProgressCursor
        )
        XCTAssertEqual(advancingProgress.hasProgress, true)
        XCTAssertNotEqual(
            advancingProgress.progressIdentity,
            firstProgressIdentity
        )
        XCTAssertEqual(
            updaterTracker.observe(
                assessment: advancingProgress,
                at: startedAt.addingTimeInterval(2),
                idleTimeout: 10
            ).continuity,
            .recentOrAdvancing
        )
        let advancingCursor = try XCTUnwrap(advancingProgress.nextCursor)

        // The real 2026-08-14 install completed win32 at 10:02:32, restarted,
        // then began the win64 stage at 10:02:33. A poll in that one-second gap
        // must keep the per-stage completion provisional.
        try bootstrapHandle.write(contentsOf: Data((
            "[2026-08-14 10:02:32] 업데이트 완료! Steam 실행 중...\n" +
            "[2026-08-14 10:02:32] Shutdown\n"
        ).utf8))
        let firstStageCompletion = steamManager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: advancingCursor
        )
        XCTAssertFalse(firstStageCompletion.observedProgress)
        XCTAssertTrue(firstStageCompletion.observedCompletion)
        XCTAssertEqual(
            updaterTracker.observe(
                assessment: firstStageCompletion,
                at: startedAt.addingTimeInterval(3),
                idleTimeout: 10
            ).state,
            .inProgress,
            "a per-architecture completion row is not yet whole-update completion"
        )

        // Startup/verification are phase markers, not terminal completion; the
        // later progress in this same source supersedes the candidate.
        try bootstrapHandle.write(contentsOf: Data((
            "\n" +
            "[2026-08-14 10:02:32] Startup - updater built Jan 29 2026 14:35:32\n" +
            "[2026-08-14 10:02:33] Verification complete\n" +
            "[2026-08-14 10:02:33] 업데이트 다운로드 중...(1/200,000KB)\n"
        ).utf8))
        let secondStageProgress = steamManager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: updaterTracker.cursor
        )
        XCTAssertEqual(secondStageProgress.hasProgress, true)
        XCTAssertTrue(secondStageProgress.observedProgress)
        XCTAssertFalse(secondStageProgress.observedCompletion)
        XCTAssertEqual(
            updaterTracker.observe(
                assessment: secondStageProgress,
                at: startedAt.addingTimeInterval(4),
                idleTimeout: 10
            ).state,
            .inProgress
        )
        let secondStageCursor = try XCTUnwrap(secondStageProgress.nextCursor)

        // A later caller may see only stdout completion. It cannot erase the
        // bootstrap source's still-current progress because the sources have no
        // trustworthy global ordering and the tracker owns both source states.
        let stdoutHandle = try FileHandle(forWritingTo: stdout)
        try stdoutHandle.seekToEnd()
        try stdoutHandle.write(contentsOf: Data(
            "업데이트 완료! Steam 실행 중...\n".utf8
        ))
        try stdoutHandle.close()
        let crossPollCompletion = steamManager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: secondStageCursor
        )
        XCTAssertFalse(crossPollCompletion.observedProgress)
        XCTAssertTrue(crossPollCompletion.observedCompletion)
        XCTAssertEqual(
            updaterTracker.observe(
                assessment: crossPollCompletion,
                at: startedAt.addingTimeInterval(5),
                idleTimeout: 10
            ).state,
            .inProgress,
            "stdout completion cannot clear bootstrap progress remembered from the previous poll"
        )

        // The same conservative rule applies when a later batch contains both
        // a fresh stdout completion and fresh bootstrap progress.
        let repeatedStdoutHandle = try FileHandle(forWritingTo: stdout)
        try repeatedStdoutHandle.seekToEnd()
        try repeatedStdoutHandle.write(contentsOf: Data(
            "업데이트 완료! Steam 실행 중...\n".utf8
        ))
        try repeatedStdoutHandle.close()
        try bootstrapHandle.write(contentsOf: Data(
            "업데이트 다운로드 중...(2/200,000KB)\n".utf8
        ))
        let crossSourceConflict = steamManager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: updaterTracker.cursor
        )
        XCTAssertEqual(crossSourceConflict.hasProgress, true)
        XCTAssertTrue(crossSourceConflict.observedProgress)
        XCTAssertFalse(crossSourceConflict.observedCompletion)
        XCTAssertEqual(
            updaterTracker.observe(
                assessment: crossSourceConflict,
                at: startedAt.addingTimeInterval(6),
                idleTimeout: 10
            ).continuity,
            .recentOrAdvancing
        )
        let conflictCursor = try XCTUnwrap(crossSourceConflict.nextCursor)

        try bootstrapHandle.write(contentsOf: Data(
            "업데이트 완료! Steam 실행 중...\n".utf8
        ))
        let completedUpdate = steamManager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: conflictCursor
        )
        XCTAssertEqual(completedUpdate.hasProgress, false)
        XCTAssertFalse(completedUpdate.observedProgress)
        XCTAssertTrue(completedUpdate.observedCompletion)
        XCTAssertEqual(
            updaterTracker.observe(
                assessment: completedUpdate,
                at: startedAt.addingTimeInterval(7),
                idleTimeout: 10
            ).state,
            .inProgress,
            "per-stage completion must remain provisional long enough for a later architecture update to start"
        )
        let postCompletionQuiet = steamManager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: updaterTracker.cursor
        )
        XCTAssertEqual(
            updaterTracker.observe(
                assessment: postCompletionQuiet,
                at: startedAt.addingTimeInterval(9.1),
                idleTimeout: 10
            ).state,
            .notInProgress
        )
        let completedCursor = try XCTUnwrap(completedUpdate.nextCursor)

        try FileManager.default.removeItem(at: stdout)
        try bootstrapHandle.write(contentsOf: Data(
            "Startup - no update required\n".utf8
        ))
        let vanishedRequiredSource = steamManager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: completedCursor
        )
        XCTAssertNil(vanishedRequiredSource.hasProgress)
        XCTAssertEqual(vanishedRequiredSource.state, .changedDuringRead)
        XCTAssertTrue(vanishedRequiredSource.evidenceUnavailable)
        XCTAssertTrue(
            vanishedRequiredSource.sources.contains {
                $0.url == stdout && $0.required &&
                    $0.state == .changedDuringRead
            }
        )

        try Data().write(to: stdout)
        try FileManager.default.removeItem(at: logDirectory)
        let redirectedLogs = temporaryRoot.appending(
            path: "UntrustedSteamLogs",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: redirectedLogs, withIntermediateDirectories: true)
        try "Downloading update (50,000/100,000KB)\n".write(
            to: redirectedLogs.appending(path: "bootstrap_log.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: logDirectory,
            withDestinationURL: redirectedLogs
        )
        let unsafeParentAssessment = steamManager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: updateCursor
        )
        XCTAssertNil(unsafeParentAssessment.hasProgress)
        XCTAssertEqual(unsafeParentAssessment.state, .unsafe)
        XCTAssertTrue(unsafeParentAssessment.evidenceUnavailable)
        XCTAssertFalse(
            steamManager.steamBootstrapUpdateLogHasProgress(
                result: result,
                steamDirectory: steamDirectory,
                since: updateCursor
            )
        )
    }

    func testBootstrapStableReadWindowAcceptsOnlyMonotonicAppendOutsideExactRereadRange() {
        let captured = Data("Downloading update (100,514/235,360KB)\n".utf8)
        let initial = SteamManager.BootstrapEvidenceFileMetadata(
            deviceNumber: 11,
            fileNumber: 22,
            byteCount: 1_024,
            modificationSeconds: 100,
            modificationNanoseconds: 0
        )
        let appendAfterRead = SteamManager.BootstrapEvidenceFileMetadata(
            deviceNumber: 11,
            fileNumber: 22,
            byteCount: 1_088,
            modificationSeconds: 101,
            modificationNanoseconds: 0
        )

        XCTAssertTrue(SteamManager.bootstrapEvidenceReadWindowIsStable(
            initialMetadata: initial,
            postReadMetadata: appendAfterRead,
            postRereadMetadata: appendAfterRead,
            capturedData: captured,
            rereadData: captured
        ))

        var replacement = appendAfterRead
        replacement.fileNumber += 1
        XCTAssertFalse(SteamManager.bootstrapEvidenceReadWindowIsStable(
            initialMetadata: initial,
            postReadMetadata: replacement,
            postRereadMetadata: replacement,
            capturedData: captured,
            rereadData: captured
        ))

        var wrongDevice = appendAfterRead
        wrongDevice.deviceNumber += 1
        XCTAssertFalse(SteamManager.bootstrapEvidenceReadWindowIsStable(
            initialMetadata: initial,
            postReadMetadata: wrongDevice,
            postRereadMetadata: wrongDevice,
            capturedData: captured,
            rereadData: captured
        ))

        var truncation = appendAfterRead
        truncation.byteCount = initial.byteCount - 1
        XCTAssertFalse(SteamManager.bootstrapEvidenceReadWindowIsStable(
            initialMetadata: initial,
            postReadMetadata: truncation,
            postRereadMetadata: truncation,
            capturedData: captured,
            rereadData: captured
        ))

        XCTAssertFalse(SteamManager.bootstrapEvidenceReadWindowIsStable(
            initialMetadata: initial,
            postReadMetadata: appendAfterRead,
            postRereadMetadata: appendAfterRead,
            capturedData: captured,
            rereadData: Data(
                "Downloading update (100,515/235,360KB)\n".utf8
            )
        ))
    }

    func testBootstrapProgressCursorRejectsNoiseReplacementAndTailWindowMovement() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayBootstrapCursor-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let manager = makeSteamManager(pathManager: pathManager)
        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let bootstrapLog = logs.appending(path: "bootstrap_log.txt")
        try "Downloading update (previous launch)\n".write(
            to: bootstrapLog,
            atomically: true,
            encoding: .utf8
        )
        let launchCursor = SteamLaunchDiagnosticsReporter()
            .captureSteamWebHelperStartupLogCursor(in: steamDirectory)
        let stdout = root.appending(path: "launch.stdout")
        let stderr = root.appending(path: "launch.stderr")
        try Data().write(to: stdout)
        try Data().write(to: stderr)
        let now = Date()
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: root.appending(path: "wine"),
            arguments: [],
            startedAt: now,
            endedAt: now,
            exitCode: 0,
            stdoutLog: stdout,
            stderrLog: stderr,
            didTimeOut: false,
            waitedForExit: false
        )
        let handle = try FileHandle(forWritingTo: bootstrapLog)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            "Downloading update (10,000/100,000KB)\n".utf8
        ))
        let first = manager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: manager.bootstrapUpdateSourceCursor(from: launchCursor)
        )
        XCTAssertTrue(first.observedProgress)
        let firstCursor = try XCTUnwrap(first.nextCursor)

        try handle.write(contentsOf: Data("unrelated timestamp-free noise\n".utf8))
        let noise = manager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: firstCursor
        )
        XCTAssertFalse(noise.observedProgress)
        XCTAssertNil(noise.progressIdentity)
        let noiseCursor = try XCTUnwrap(noise.nextCursor)

        let mutationOffset = noiseCursor.bootstrapLog.byteCount - 2
        try handle.seek(toOffset: mutationOffset)
        try handle.write(contentsOf: Data("X".utf8))
        try handle.seekToEnd()
        let preCursorMutation = manager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: noiseCursor
        )
        XCTAssertTrue(preCursorMutation.evidenceUnavailable)
        XCTAssertFalse(preCursorMutation.observedProgress)
        XCTAssertEqual(preCursorMutation.nextCursor, noiseCursor)

        try "Downloading update (replacement file)\n".write(
            to: bootstrapLog,
            atomically: true,
            encoding: .utf8
        )
        let replacement = manager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: noiseCursor
        )
        XCTAssertTrue(replacement.evidenceUnavailable)
        XCTAssertFalse(replacement.observedProgress)
        XCTAssertEqual(replacement.nextCursor, noiseCursor)

        let replacementLaunchCursor = SteamLaunchDiagnosticsReporter()
            .captureSteamWebHelperStartupLogCursor(in: steamDirectory)
        let oversizedHandle = try FileHandle(forWritingTo: bootstrapLog)
        try oversizedHandle.seekToEnd()
        try oversizedHandle.write(contentsOf: Data(repeating: 0x78, count: 128_001))
        try oversizedHandle.close()
        let oversized = manager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: manager.bootstrapUpdateSourceCursor(
                from: replacementLaunchCursor
            )
        )
        XCTAssertEqual(oversized.state, .truncated)
        XCTAssertTrue(oversized.evidenceUnavailable)
        XCTAssertFalse(oversized.observedProgress)
        XCTAssertEqual(
            oversized.nextCursor?.bootstrapLog,
            replacementLaunchCursor.bootstrapLog
        )
    }

    func testBootstrapProgressCursorDiscardsPrelaunchPartialSuffixButConsumesLaunchPartialOnce() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayBootstrapPartialCursor-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let manager = makeSteamManager(pathManager: pathManager)
        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let bootstrapLog = logs.appending(path: "bootstrap_log.txt")
        try "pre-launch unfinished row ".write(
            to: bootstrapLog,
            atomically: true,
            encoding: .utf8
        )
        let launchCursor = SteamLaunchDiagnosticsReporter()
            .captureSteamWebHelperStartupLogCursor(in: steamDirectory)
        XCTAssertFalse(launchCursor.bootstrapLog.endsAtLineBoundary)

        let stdout = root.appending(path: "launch.stdout")
        let stderr = root.appending(path: "launch.stderr")
        try Data().write(to: stdout)
        try Data().write(to: stderr)
        let now = Date()
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: root.appending(path: "wine"),
            arguments: [],
            startedAt: now,
            endedAt: now,
            exitCode: 0,
            stdoutLog: stdout,
            stderrLog: stderr,
            didTimeOut: false,
            waitedForExit: false
        )
        let handle = try FileHandle(forWritingTo: bootstrapLog)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            "Downloading update (pre-launch row suffix)\n".utf8
        ))
        let discardedSuffix = manager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: manager.bootstrapUpdateSourceCursor(from: launchCursor)
        )
        XCTAssertEqual(discardedSuffix.hasProgress, false)
        XCTAssertFalse(discardedSuffix.observedProgress)
        let discardedCursor = try XCTUnwrap(discardedSuffix.nextCursor)
        XCTAssertTrue(discardedCursor.bootstrapLog.endsAtLineBoundary)

        try handle.write(contentsOf: Data(
            "Downloading update (fresh complete row)\nlaunch partial ".utf8
        ))
        let freshRow = manager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: discardedCursor
        )
        XCTAssertEqual(freshRow.hasProgress, true)
        let freshCursor = try XCTUnwrap(freshRow.nextCursor)

        try handle.write(contentsOf: Data(
            "Downloading update (continued and completed)\n".utf8
        ))
        let completedLaunchPartial = manager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: freshCursor
        )
        XCTAssertEqual(completedLaunchPartial.hasProgress, true)
        let completedPartialCursor = try XCTUnwrap(
            completedLaunchPartial.nextCursor
        )
        let noDuplicate = manager.steamBootstrapUpdateLogAssessment(
            result: result,
            steamDirectory: steamDirectory,
            since: completedPartialCursor
        )
        XCTAssertEqual(noDuplicate.hasProgress, false)
        XCTAssertFalse(noDuplicate.observedProgress)
    }

    func testLaunchSteamRejectsWineD3DFallbackWhenRendererPolicyCannotBeResolved() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamLaunchRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let system32 = prefix.appending(path: "drive_c/windows/system32", directoryHint: .isDirectory)
        let runnerRoot = temporaryRoot.appending(path: "ForgePlayRuntime", directoryHint: .isDirectory)
        let launcherDirectory = runnerRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let wineRoot = runnerRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        let invocationLog = temporaryRoot.appending(path: "steam-launch-unavailable-renderer-should-not-run.log")
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        env | sort
        printf '%s\\n' "$@"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let capability = WindowsRuntimeService.inspectRuntimeCapability(for: launcher)

        XCTAssertFalse(capability.supportsModernDirect3DGames)
        XCTAssertFalse(capability.supportsWindowsSteamClientLaunches)
        XCTAssertFalse(capability.supportsManagedSteamGameLaunches)
        XCTAssertTrue(capability.limitations.contains("missing-direct3d-renderer"))
        do {
            _ = try await steamManager.launchSteam(
                runtimeExecutable: launcher,
                verificationMode: .conformance,
                rendererPolicy: .d3dMetal
            )
            XCTFail("An unavailable selected renderer must fail before Steam launch")
        } catch SteamLaunchError.rendererPolicyUnavailable(let message) {
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("Unexpected launch error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocationLog.path))
    }

    func testLaunchSteamRejectsUnverifiedDXVKBeforeSpawn() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamLaunchRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let system32 = prefix.appending(path: "drive_c/windows/system32", directoryHint: .isDirectory)
        let runnerRoot = temporaryRoot.appending(path: "ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runnerRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcherDirectory = runnerRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let runtimeLib = wineRoot.appending(path: "lib", directoryHint: .isDirectory)
        let icdDirectory = wineRoot.appending(path: "etc/vulkan/icd.d", directoryHint: .isDirectory)
        let dxvkRenderer = runnerRoot.appending(path: "Frameworks/renderer/dxvk", directoryHint: .isDirectory)
        let dxvkWindowsX64 = dxvkRenderer.appending(path: "wine/x86_64-windows", directoryHint: .isDirectory)
        let dxvkWindowsX86 = dxvkRenderer.appending(path: "wine/i386-windows", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        let invocationLog = temporaryRoot.appending(
            path: "unverified-dxvk-should-not-spawn.log"
        )
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimeLib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: icdDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dxvkWindowsX64, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dxvkWindowsX86, withIntermediateDirectories: true)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try Data().write(to: runtimeLib.appending(path: "libgnutls.30.dylib"))
        try Data().write(to: runtimeLib.appending(path: "libfreetype.6.dylib"))
        try Data().write(to: runtimeLib.appending(path: "libvulkan.1.dylib"))
        try Data().write(to: runtimeLib.appending(path: "libMoltenVK.dylib"))
        for dxvkWindows in [dxvkWindowsX64, dxvkWindowsX86] {
            try Data("dxvk d3d8".utf8).write(to: dxvkWindows.appending(path: "d3d8.dll"))
            try Data("dxvk d3d9".utf8).write(to: dxvkWindows.appending(path: "d3d9.dll"))
            try Data("dxvk d3d10core".utf8).write(
                to: dxvkWindows.appending(path: "d3d10core.dll")
            )
            try Data("dxvk d3d11".utf8).write(to: dxvkWindows.appending(path: "d3d11.dll"))
            try Data("dxvk dxgi".utf8).write(to: dxvkWindows.appending(path: "dxgi.dll"))
        }
        try #"{"ICD":{"library_path":"../../lib/libMoltenVK.dylib","api_version":"1.4.0"}}"#
            .write(to: icdDirectory.appending(path: "MoltenVK_icd.json"), atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "\(invocationLog.path)"
        \(steamRegistryRecordingShellPreamble())
        env | sort
        printf '%s\\n' "$@"
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let capability = WindowsRuntimeService.inspectRuntimeCapability(
            for: launcher
        )
        XCTAssertEqual(
            capability.rendererRuntimeGates[.vulkan],
            .unverified(
                technicalDetail:
                    "no authenticated successful DXVK DXGI device gate exists for this Runtime generation"
            )
        )
        XCTAssertTrue(
            capability.limitations.contains("dxvk-runtime-gate-unverified")
        )
        XCTAssertFalse(
            SteamRendererPolicyPreference.vulkan.isSatisfied(by: capability)
        )
        do {
            _ = try await steamManager.launchSteam(
                runtimeExecutable: launcher,
                verificationMode: .conformance,
                rendererPolicy: .vulkan,
                videoMemorySizeMB: 4_096
            )
            XCTFail("unverified DXVK must fail admission before Steam launch")
        } catch SteamLaunchError.rendererPolicyUnavailable(let message) {
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("Unexpected launch error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocationLog.path))
    }

    func testLaunchSteamAnnotatesRecentSteamCrashDump() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamLaunchRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let runtimeRoot = temporaryRoot.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcherDirectory = runtimeRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        if [ "$1" = "wineserver" ]; then
          exit 0
        fi
        mkdir -p "$WINEPREFIX/drive_c/Program Files (x86)/Steam/dumps"
        printf 'MDMP' > "$WINEPREFIX/drive_c/Program Files (x86)/Steam/dumps/crash_steam.exe_test.dmp"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try await applySteamLaunchPolicy(steamManager: steamManager, prefix: prefix, launcher: launcher)

        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .conformance,
            rendererPolicy: .d3dMetal
        )
        let diagnosticLog = try XCTUnwrap(result.diagnosticLog)
        let diagnostics = try String(contentsOf: diagnosticLog, encoding: .utf8)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stderrLog.lastPathComponent.hasSuffix("_stderr.log"))
        XCTAssertTrue(diagnosticLog.lastPathComponent.hasSuffix("_stderr.diagnostics.log"))
        XCTAssertTrue(diagnostics.contains("Raw stderr log: \(result.stderrLog.path)"))
        XCTAssertTrue(diagnostics.contains("ForgePlay detected Steam crash dump(s) after launch."))
        XCTAssertTrue(diagnostics.contains("crash_steam.exe_test.dmp"))
    }

    func testCrashDumpDifferenceExcludesPreexistingDumpAndIncludesModifiedOrNewDump() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCrashDumpDifference-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = root.appending(path: "crash_existing.dmp")
        let modified = root.appending(path: "crash_modified.dmp")
        try Data("existing".utf8).write(to: existing)
        try Data("before".utf8).write(to: modified)
        let reporter = SteamLaunchDiagnosticsReporter()
        let before = reporter.recentSteamCrashDumpScan(
            in: root,
            since: Date(timeIntervalSince1970: 0)
        )

        try Data("after-with-different-size".utf8).write(to: modified)
        let added = root.appending(path: "crash_added.dmp")
        try Data("added".utf8).write(to: added)
        let after = reporter.recentSteamCrashDumpScan(
            in: root,
            since: Date(timeIntervalSince1970: 0)
        )
        let difference = SteamManager.newSteamCrashDumps(
            in: after,
            excluding: before.fingerprints
        )

        let differencePaths = Set(difference.map { $0.resolvingSymlinksInPath().path })
        XCTAssertFalse(differencePaths.contains(existing.resolvingSymlinksInPath().path))
        XCTAssertTrue(differencePaths.contains(modified.resolvingSymlinksInPath().path))
        XCTAssertTrue(differencePaths.contains(added.resolvingSymlinksInPath().path))
    }

    func testUnreadableCrashDumpBaselineIsIncompleteAndDoesNotClassifyLaterReadableDumpAsOld() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayUnreadableCrashDumpFingerprint-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dump = root.appending(path: "crash_fingerprint_retry.dmp")
        try Data("MDMP-before".utf8).write(to: dump)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dump.path)

        let reporter = SteamLaunchDiagnosticsReporter()
        let crashDumpObservationContext = reporter.beginCrashDumpObservationContext()
        defer { reporter.discardCrashDumpObservationContext(crashDumpObservationContext) }
        let baseline = reporter.recentSteamCrashDumpScan(
            in: root,
            since: Date(timeIntervalSince1970: 0),
            observationContext: crashDumpObservationContext
        )
        XCTAssertEqual(baseline.state, .unreadable)
        XCTAssertTrue(baseline.items.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dump.path)
        try Data("MDMP-after-readable".utf8).write(to: dump)
        let after = reporter.recentSteamCrashDumpScan(
            in: root,
            since: Date(timeIntervalSince1970: 0),
            observationContext: crashDumpObservationContext
        )
        XCTAssertEqual(after.state, .captured)
        let difference = SteamManager.newSteamCrashDumps(
            in: after,
            excluding: baseline.fingerprints
        )
        XCTAssertEqual(
            difference.map { $0.resolvingSymlinksInPath().path },
            [dump.resolvingSymlinksInPath().path]
        )

        let stdout = root.appending(path: "launch_stdout.log")
        let stderr = root.appending(path: "launch_stderr.log")
        try Data("stdout\n".utf8).write(to: stdout)
        try Data("stderr\n".utf8).write(to: stderr)
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: root.appending(path: "wine"),
            arguments: ["steam.exe"],
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            exitCode: 0,
            stdoutLog: stdout,
            stderrLog: stderr,
            didTimeOut: false,
            waitedForExit: false
        )
        let diagnosticURL = try reporter.writeDiagnostics(
            for: result,
            preflightShutdown: nil,
            failureShutdown: nil,
            failureShutdownError: nil,
            dumps: difference,
            steamDirectory: root,
            renderingIssue: nil,
            dumpsAfter: difference,
            gateStatus: .success,
            launchEnvironmentSummary: [],
            crashDumpObservationContext: crashDumpObservationContext,
            since: Date(timeIntervalSince1970: 0)
        )
        let diagnostics = try String(contentsOf: diagnosticURL, encoding: .utf8)
        XCTAssertTrue(diagnostics.contains("crash dump scan unreadable"), diagnostics)
        XCTAssertTrue(diagnostics.contains("- Status: FAILED"), diagnostics)
        XCTAssertTrue(diagnostics.contains(dump.path), diagnostics)
        XCTAssertEqual(
            reporter.evidenceAssessment(for: diagnosticURL)?.completeness,
            .incomplete
        )
    }

    func testConformanceTerminalWebHelperFailureStopsSteamDespiteBootstrapUpdateProgress() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamLaunchRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let runtimeRoot = temporaryRoot.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcherDirectory = runtimeRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        if [ "$1" = "wineserver" ]; then
          exit 0
        fi
        log_dir="$WINEPREFIX/drive_c/Program Files (x86)/Steam/logs"
        mkdir -p "$log_dir"
        : > "$log_dir/webhelper_gpu.txt"
        timestamp="$(date '+[%Y-%m-%d %H:%M:%S]')"
        i=0
        while [ "$i" -lt 300 ]; do
          i=$((i + 1))
          printf '%s webhelper filler line %s\\r\\n' "$timestamp" "$i" >> "$log_dir/webhelper_gpu.txt"
        done
        printf '%s eglInitialize D3D11 failed with error EGL_NOT_INITIALIZED\\r\\n' "$timestamp" >> "$log_dir/webhelper_gpu.txt"
        printf '%s Internal Vulkan error (-9)\\r\\n' "$timestamp" >> "$log_dir/webhelper_gpu.txt"
        printf '%s GL implementation parts: (gl=disabled,angle=none)\\r\\n' "$timestamp" >> "$log_dir/webhelper_gpu.txt"
        printf '%s GPU process crashed too many times with SwiftShader\\r\\n' "$timestamp" >> "$log_dir/webhelper_gpu.txt"
        printf '%s steamwebhelper.exe --type=gpu-process --use-gl=angle --use-angle=swiftshader-webgl\\r\\n' "$timestamp" >> "$log_dir/webhelper_gpu.txt"
        printf '%s Loaded C:\\\\Program Files (x86)\\\\Steam\\\\bin\\\\cef\\\\cef.win64\\\\vk_swiftshader.dll\\r\\n' "$timestamp" >> "$log_dir/webhelper_gpu.txt"
        printf '%s ANGLE_DEFAULT_PLATFORM=d3d11 and d3d11.dll were observed before SwiftShader fallback\\r\\n' "$timestamp" >> "$log_dir/webhelper_gpu.txt"
        printf '%s Downloading update (332,874/336,229KB)\\r\\n' "$timestamp" > "$log_dir/bootstrap_log.txt"
        cat > "$log_dir/steamui_html.txt" <<'LOG'
        CreateBrowser PopupHTMLWindow (-2147483648, -2147483648) 0x0
        BrowserReady
        LOG
        cat > "$log_dir/steamui_login.txt" <<'LOG'
        WaitingForCredentials
        UI Request: connect
        LOG
        printf '%s Error: CFindCurrentBucketJob::YieldingRunTestProgram: process exit code 3221225781: .\\bin\\gldriverquery.exe\r\n' "$timestamp" > "$log_dir/shader_log.txt"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try await applySteamLaunchPolicy(steamManager: steamManager, prefix: prefix, launcher: launcher)
        try? FileManager.default.removeItem(
            at: steamDirectory.appending(path: "logs")
        )

        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .conformance,
            rendererPolicy: .d3dMetal
        )
        let diagnosticLog = try XCTUnwrap(result.diagnosticLog)
        let diagnostics = try String(contentsOf: diagnosticLog, encoding: .utf8)
        let evidenceDirectory = diagnosticLog
            .deletingPathExtension()
            .appendingPathExtension("diagnostics")
        let bootstrapTail = try String(
            contentsOf: evidenceDirectory.appending(
                path: "bootstrap-tail.txt"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.processExitCode, 0)
        XCTAssertEqual(result.forgePlayStatusCode, SteamManager.steamRenderingFailureExitCode)
        XCTAssertEqual(result.steamUIVerificationState, .blackScreenSuspected)
        XCTAssertNotEqual(result.steamUIVerificationState, .rendered)
        XCTAssertEqual(result.steamUIStartupRecoveryAttemptCount, 0)
        XCTAssertNil(result.steamUIStartupRecoveryReason)
        XCTAssertTrue(
            bootstrapTail.contains("Downloading update (332,874/336,229KB)"),
            bootstrapTail
        )
        XCTAssertTrue(diagnostics.contains("Pre-launch Steam Prefix process shutdown:"))
        XCTAssertTrue(diagnostics.contains("Post-failure Steam Prefix process shutdown:"))
        XCTAssertFalse(
            diagnostics.contains("Steam bootstrap update was still in progress"),
            diagnostics
        )
        XCTAssertTrue(diagnostics.contains("unusable Windows Steam CEF/WebHelper rendering state after this launch"))
        XCTAssertTrue(diagnostics.contains("visible Steam window is expected to be black or unusable"))
        XCTAssertTrue(diagnostics.contains("Windows Steam was stopped because the visible Steam window is expected to be black or unusable."))
        XCTAssertTrue(diagnostics.contains("Steam webhelper GPU log tail:"))
        XCTAssertTrue(diagnostics.contains("Steam UI HTML log tail:"))
        XCTAssertTrue(diagnostics.contains("Steam login log tail:"))
        XCTAssertTrue(diagnostics.contains("Steam shader log tail:"))
        XCTAssertTrue(diagnostics.contains("black-window signature"))
        XCTAssertTrue(
            diagnostics.contains("gldriverquery.exe failed with a missing-dependency style exit code"),
            diagnostics
        )
        XCTAssertTrue(
            diagnostics.contains("SDL3-backed sdl2-compat pair"),
            diagnostics
        )
        XCTAssertTrue(diagnostics.contains("Internal Vulkan error (-9)"))
        XCTAssertTrue(diagnostics.contains("GL implementation parts"))
        XCTAssertTrue(diagnostics.contains("SwiftShader"))
        XCTAssertTrue(
            diagnostics.contains("selected Chromium ANGLE SwiftShader/WebGL instead of the ForgePlay Runtime Direct3D/Metal renderer path"),
            diagnostics
        )
        XCTAssertTrue(
            diagnostics.contains("observed ANGLE_DEFAULT_PLATFORM/D3D11 but still fell back to SwiftShader"),
            diagnostics
        )
        XCTAssertTrue(diagnostics.contains("verify that the executable-scoped WebHelper compatibility policy reached the same attempt"))
        XCTAssertFalse(diagnostics.contains("did not hold ANGLE on D3D11"))
        XCTAssertFalse(diagnostics.contains("-cef-use-angle=d3d11"))
        XCTAssertFalse(diagnostics.contains("-cef-use-angle=vulkan"))
        XCTAssertFalse(diagnostics.contains("webhelper filler line 1"))
        XCTAssertLessThanOrEqual(
            diagnosticSectionLineCount(
                named: "Steam webhelper GPU log tail:",
                before: "Steam UI HTML log tail:",
                in: diagnostics
            ),
            80
        )
    }

    func testSteamLaunchDiagnosticsTreatsMacOSSteamIPCAsHostEvidenceOnly() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamDiagnosticsRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let steamDirectory = temporaryRoot.appending(path: "Steam", directoryHint: .isDirectory)
        let logDirectory = temporaryRoot.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let stdout = logDirectory.appending(path: "steam_launch_stdout.log")
        let stderr = logDirectory.appending(path: "steam_launch_stderr.log")
        try Data("stdout\n".utf8).write(to: stdout)
        try """
        Host process still visible: /Applications/Steam.app/Contents/MacOS/steam_osx
        Valve background IPC process: Steam.AppBundle/Contents/MacOS/ipcserver com.valvesoftware.steam.ipctool
        Windows Steam process has not produced visible UI verification evidence.
        """.write(to: stderr, atomically: true, encoding: .utf8)
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: temporaryRoot.appending(path: "wine"),
            arguments: [],
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            exitCode: 0,
            stdoutLog: stdout,
            stderrLog: stderr,
            didTimeOut: false,
            waitedForExit: false
        )
        let reporter = SteamLaunchDiagnosticsReporter()

        let diagnosticURL = try reporter.writeDiagnostics(
            for: result,
            preflightShutdown: nil,
            failureShutdown: nil,
            failureShutdownError: nil,
            dumps: [],
            steamDirectory: steamDirectory,
            renderingIssue: nil,
            hostSteamProcessesAfter: [
                MacOSSteamProcess(
                    processID: 1234,
                    command: "/Users/tester/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx"
                )
            ],
            launchTarget: SteamLaunchTarget(
                expectedRunnerPath: temporaryRoot.appending(path: "wine"),
                expectedPrefixPath: temporaryRoot.appending(path: "SteamShared"),
                expectedSteamExecutablePath: steamDirectory.appending(path: "steam.exe")
            ),
            runnerVersionEvidence: """
            runner: \(temporaryRoot.appending(path: "wine").path)
            exitCode: 0

            stdout:
            wine-11.12

            stderr:
            <empty>
            """,
            hardGateFailureReasons: [
                "screen-final.png visual evidence is missing; Windows Steam login, Steam Guard, or Library UI was not verified"
            ],
            launchEnvironmentSummary: [],
            since: Date(timeIntervalSince1970: 0)
        )
        let diagnostics = try String(contentsOf: diagnosticURL, encoding: .utf8)
        let evidenceDirectory = diagnosticURL
            .deletingPathExtension()
            .appendingPathExtension("diagnostics")
        let index = try String(
            contentsOf: evidenceDirectory.appending(path: "index.md"),
            encoding: .utf8
        )
        let hostSteamAfter = try String(
            contentsOf: evidenceDirectory.appending(path: "host-steam-after.txt"),
            encoding: .utf8
        )
        let wineVersion = try String(
            contentsOf: evidenceDirectory.appending(path: "wine-version.txt"),
            encoding: .utf8
        )

        XCTAssertTrue(diagnostics.contains("Host macOS Steam process contamination"))
        XCTAssertTrue(diagnostics.contains("PID 1234"))
        XCTAssertTrue(diagnostics.contains("newly launched while ForgePlay was attempting to start Windows Steam"))
        XCTAssertTrue(diagnostics.contains("clean Windows Steam install without importing macOS Steam state"))
        XCTAssertTrue(diagnostics.contains("macOS Steam.app or Valve ipcserver evidence was present"))
        XCTAssertTrue(diagnostics.contains("not as Windows Steam UI rendering success"))
        XCTAssertTrue(diagnostics.contains("Windows Steam process has not produced visible UI verification evidence."))
        XCTAssertTrue(index.contains("Status: FAILED"), index)
        XCTAssertTrue(index.contains("screen-final.png: missing; SUCCESS forbidden"), index)
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidenceDirectory.appending(path: "processes-before.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidenceDirectory.appending(path: "processes-after.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidenceDirectory.appending(path: "capture-complete.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidenceDirectory.appending(path: "screen-final.png.missing.txt").path))
        XCTAssertTrue(hostSteamAfter.contains("PID 1234"), hostSteamAfter)
        XCTAssertTrue(wineVersion.contains("wine-11.12"), wineVersion)
    }

    func testSteamLaunchDiagnosticsReportsWebHelperProcessPolicyWithoutClaimingRendering() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamCEFMitigationDiagnosticsRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let steamDirectory = temporaryRoot.appending(path: "Steam", directoryHint: .isDirectory)
        let steamLogDirectory = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let logDirectory = temporaryRoot.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamLogDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try """
        [2000-01-01 00:00:00] stale shader failure from a previous launch
        """.write(to: steamLogDirectory.appending(path: "shader_log.txt"), atomically: true, encoding: .utf8)
        let reporter = SteamLaunchDiagnosticsReporter()
        let logCursor = reporter.captureSteamWebHelperStartupLogCursor(in: steamDirectory)
        try """
        [2026-07-05 10:13:04] Disabling GPU acceleration: Disabled/CommandLine
        [2026-07-05 10:13:04] Disabling GPU acceleration due to --disable-gpu-compositing (browser)
        """.write(to: steamLogDirectory.appending(path: "webhelper_gpu.txt"), atomically: true, encoding: .utf8)
        try """
        [2026-07-05 10:13:05] BrowserReady: handle:65536
        """.write(to: steamLogDirectory.appending(path: "steamui_html.txt"), atomically: true, encoding: .utf8)
        try """
        [2026-07-05 10:13:05] Starting message loop
        """.write(to: steamLogDirectory.appending(path: "webhelper.txt"), atomically: true, encoding: .utf8)
        try """
        [2026-07-05 10:13:00] Startup - Steam Client launched with: "C:\\Program Files (x86)\\Steam\\steam.exe" -no-cef-sandbox
        """.write(to: steamLogDirectory.appending(path: "bootstrap_log.txt"), atomically: true, encoding: .utf8)
        let stdout = logDirectory.appending(path: "steam_launch_stdout.log")
        let stderr = logDirectory.appending(path: "steam_launch_stderr.log")
        try Data("stdout\n".utf8).write(to: stdout)
        try Data("""
        stderr
        steamwebhelper.exe --no-sandbox --in-process-gpu --disable-gpu
        steamwebhelper.exe --type=utility --utility-sub-type=network.mojom.NetworkService --no-sandbox
        """.utf8).write(to: stderr)
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: temporaryRoot.appending(path: "wine"),
            arguments: [
                "C:\\Program Files (x86)\\Steam\\steam.exe",
                "-no-cef-sandbox"
            ],
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            exitCode: 0,
            stdoutLog: stdout,
            stderrLog: stderr,
            didTimeOut: false,
            waitedForExit: false
        )
        let diagnosticURL = try reporter.writeDiagnostics(
            for: result,
            preflightShutdown: nil,
            failureShutdown: nil,
            failureShutdownError: nil,
            dumps: [],
            steamDirectory: steamDirectory,
            renderingIssue: nil,
            launchEnvironmentSummary: [],
            logCursor: logCursor,
            since: Date(timeIntervalSince1970: 0)
        )
        let diagnostics = try String(contentsOf: diagnosticURL, encoding: .utf8)

        XCTAssertTrue(diagnostics.contains("executable-scoped Steam WebHelper CEF compatibility policy"))
        XCTAssertTrue(diagnostics.contains("process-policy evidence only"))
        XCTAssertFalse(diagnostics.contains("forbidden GPU command-line override"))
        XCTAssertFalse(diagnostics.contains("runtime compatibility failure"), diagnostics)
        XCTAssertFalse(diagnostics.contains("still fell back to SwiftShader"), diagnostics)
        XCTAssertFalse(diagnostics.contains("stale shader failure"), diagnostics)
        XCTAssertFalse(diagnostics.contains("Steam shader log tail:"), diagnostics)
        XCTAssertFalse(diagnostics.contains("third-party-style"))
        XCTAssertFalse(diagnostics.contains("No known ForgePlay runtime pattern was detected"))
    }

    func testSteamLaunchEnvironmentSummaryUsesGameRendererPayloadTerminology() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamEnvironmentSummaryRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let prefix = temporaryRoot.appending(path: "Prefixes/SteamShared", directoryHint: .isDirectory)
        let runtimeRoot = temporaryRoot.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcherDirectory = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try writeD3DMetalRenderer(at: renderer)
        let summary = SteamLaunchDiagnosticsReporter().launchEnvironmentSummary(
            runtimeExecutable: launcher,
            prefix: prefix,
            rendererPolicy: .d3dMetal
        ).joined(separator: "\n")
        let summaryLines = summary.split(whereSeparator: \.isNewline).map(String.init)

        XCTAssertTrue(summary.contains("Selected game renderer payload: d3dMetal"))
        XCTAssertTrue(summary.contains("Steam and WebHelper stay on the base Wine renderer path"))
        XCTAssertTrue(summary.contains("applies only D3DMetal to game children"))
        XCTAssertTrue(summary.contains("FORGEPLAY_SYNCHRONIZATION_SELECTION: automatic"))
        XCTAssertTrue(summary.contains("FORGEPLAY_SYNCHRONIZATION_BACKEND: server"))
        XCTAssertFalse(summary.contains("WINEMSYNC:"))
        XCTAssertFalse(summary.contains("WINEESYNC:"))
        XCTAssertTrue(summary.contains("MTL_HUD_ENABLED: 0"))
        XCTAssertTrue(summary.contains("ForgePlay direct runtime dependency payload: present"))
        XCTAssertFalse(summaryLines.contains { $0.hasPrefix("- WINEDLLOVERRIDES:") })
        XCTAssertFalse(summaryLines.contains { $0.hasPrefix("- D3DMETAL_FRAMEWORK_PATH:") })
        XCTAssertTrue(summary.contains("FORGEPLAY_GAME_RENDERER_POLICY_ENABLED: 1"))
        XCTAssertTrue(summary.contains("FORGEPLAY_GAME_RENDERER_POLICY: d3dMetal"))
        XCTAssertTrue(summary.contains("FORGEPLAY_GAME_RENDERER_DLL_PATH_X64: Z:"))
        XCTAssertFalse(summary.contains("FORGEPLAY_GAME_RENDERER_DLL_PATH_X86:"))
        XCTAssertTrue(summary.contains("FORGEPLAY_GAME_RENDERER_ENV_WINEDLLOVERRIDES:"))
        XCTAssertTrue(summary.contains("VK_ICD_FILENAMES:"))
        XCTAssertTrue(summary.contains("MoltenVK_icd.json"))
        XCTAssertFalse(summaryLines.contains("- VK_ICD_FILENAMES: /dev/null"))
        XCTAssertFalse(summary.contains("Requested game graphics backend"))
        XCTAssertFalse(summary.contains("Game renderer payload is injected into the Windows Steam client process"))
        XCTAssertFalse(summary.contains("Steam client game renderer payload"))
    }

    func testSteamLaunchDiagnosticsDetectsNoAvailableRenderersAsBlackScreenSignature() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamNoAvailableRenderers-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let steamDirectory = temporaryRoot.appending(path: "Steam", directoryHint: .isDirectory)
        let logDirectory = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try """
        [2026-07-04 20:04:40] [ERROR:gl_display.cc(508)] EGL Driver message (Critical) eglInitialize: No available renderers.
        [2026-07-04 20:04:40] [ERROR:gl_display.cc(931)] eglInitialize SwANGLE failed with error EGL_NOT_INITIALIZED
        """.write(to: logDirectory.appending(path: "webhelper_gpu.txt"), atomically: true, encoding: .utf8)
        try """
        CreateBrowser PopupHTMLWindow (-2147483648, -2147483648) 0x0
        BrowserReady
        """.write(to: logDirectory.appending(path: "steamui_html.txt"), atomically: true, encoding: .utf8)
        try """
        WaitingForCredentials
        UI Request: connect
        """.write(to: logDirectory.appending(path: "steamui_login.txt"), atomically: true, encoding: .utf8)

        let issue = SteamLaunchDiagnosticsReporter().detectSteamWebHelperRenderingFailure(
            in: steamDirectory,
            since: Date(timeIntervalSince1970: 0)
        )

        XCTAssertNotNil(issue)
        XCTAssertTrue(issue?.webHelperGPUTail.joined(separator: "\n").contains("No available renderers") == true)
    }

    func testSteamLaunchDiagnosticsTreatsCEFFatalSharedContextAsRenderingFailure() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamCEFFatalContext-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let steamDirectory = temporaryRoot.appending(path: "Steam", directoryHint: .isDirectory)
        let logDirectory = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try "BrowserReady: handle:65536\n".write(
            to: logDirectory.appending(path: "steamui_html.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "ContextResult::kFatalFailure: Failed to create shared context for virtualization\n".write(
            to: logDirectory.appending(path: "cef_log.txt"),
            atomically: true,
            encoding: .utf8
        )

        let issue = SteamLaunchDiagnosticsReporter().detectSteamWebHelperRenderingFailure(
            in: steamDirectory,
            since: Date(timeIntervalSince1970: 0)
        )

        XCTAssertNotNil(issue)
        XCTAssertEqual(issue?.cefLogEvidence.state, .captured)
        XCTAssertTrue(
            issue?.cefLogTail.joined(separator: "\n")
                .contains("Failed to create shared context for virtualization") == true
        )
    }

    func testRenderingIssueDoesNotPromoteUnsafeCompanionLogToCapturedEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRenderingIssueUnsafeEvidence-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let steamDirectory = root.appending(path: "Steam", directoryHint: .isDirectory)
        let logs = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        let runLogs = root.appending(path: "RunLogs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runLogs, withIntermediateDirectories: true)
        try """
        [2026-07-16 10:00:00] [ERROR:gl_display.cc] No available renderers.
        [2026-07-16 10:00:00] Initialization of all EGL display types failed.
        [2026-07-16 10:00:00] [ERROR:egl_util.cc] EGL_NOT_INITIALIZED
        """.write(
            to: logs.appending(path: "webhelper_gpu.txt"),
            atomically: true,
            encoding: .utf8
        )
        let unsafeTarget = root.appending(path: "outside-steamui-html.txt")
        try "BrowserReady from an untrusted source\n".write(
            to: unsafeTarget,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: logs.appending(path: "steamui_html.txt"),
            withDestinationURL: unsafeTarget
        )

        let reporter = SteamLaunchDiagnosticsReporter()
        let issue = try XCTUnwrap(reporter.detectSteamWebHelperRenderingFailure(
            in: steamDirectory,
            since: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(issue.webHelperGPUEvidence.state, .captured)
        XCTAssertEqual(issue.steamUIHTMLEvidence.state, .unsafe)

        let stdout = runLogs.appending(path: "steam_stdout.log")
        let stderr = runLogs.appending(path: "steam_stderr.log")
        try Data("stdout\n".utf8).write(to: stdout)
        try Data("stderr\n".utf8).write(to: stderr)
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: root.appending(path: "wine"),
            arguments: ["steam.exe"],
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            exitCode: 0,
            stdoutLog: stdout,
            stderrLog: stderr,
            didTimeOut: false,
            waitedForExit: false
        )
        let diagnosticURL = try reporter.writeDiagnostics(
            for: result,
            preflightShutdown: nil,
            failureShutdown: nil,
            failureShutdownError: nil,
            dumps: [],
            steamDirectory: steamDirectory,
            renderingIssue: issue,
            gateStatus: .success,
            launchEnvironmentSummary: [],
            since: Date(timeIntervalSince1970: 0)
        )
        let diagnostics = try String(contentsOf: diagnosticURL, encoding: .utf8)
        XCTAssertTrue(diagnostics.contains("steamui_html.txt: unsafe"), diagnostics)
        XCTAssertFalse(diagnostics.contains("steamui_html.txt: captured"), diagnostics)
        XCTAssertTrue(diagnostics.contains("- Status: FAILED"), diagnostics)
        XCTAssertEqual(
            reporter.evidenceAssessment(for: diagnosticURL)?.completeness,
            .incomplete
        )
    }

    func testSteamWebHelperStartupWaitReturnsPromptlyWhenCancelled() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCancelledStartupWait-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        let reporter = SteamLaunchDiagnosticsReporter()
        let cursor = reporter.captureSteamWebHelperStartupLogCursor(in: temporaryRoot)
        let waitTask = Task {
            await reporter.waitForSteamWebHelperStartup(
                in: temporaryRoot,
                since: cursor,
                timeout: 60,
                pollInterval: 5
            )
        }
        await Task.yield()

        let cancelledAt = Date()
        waitTask.cancel()
        let observation = await waitTask.value

        XCTAssertEqual(observation.state, .timedOut)
        XCTAssertTrue(observation.shouldRetry)
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1)
    }

    func testSteamWebHelperRenderingWaitReturnsPromptlyWhenCancelled() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCancelledRenderingWait-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        let reporter = SteamLaunchDiagnosticsReporter()
        let waitTask = Task {
            await reporter.waitForSteamWebHelperRenderingFailure(
                in: temporaryRoot,
                since: Date(),
                timeout: 60,
                pollInterval: 5
            )
        }
        await Task.yield()

        let cancelledAt = Date()
        waitTask.cancel()
        let issue = await waitTask.value

        XCTAssertNil(issue)
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1)
    }

    func testSteamLaunchDiagnosticsDetectsDecisiveWebHelperGPUFailureWithoutFreshLoginTail() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamDecisiveGPUFailure-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let steamDirectory = temporaryRoot.appending(path: "Steam", directoryHint: .isDirectory)
        let logDirectory = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try """
        [2026-07-05 05:54:50] [ERROR:gl_display.cc(497)] EGL Driver message (Critical) eglInitialize: No available renderers.
        [2026-07-05 05:54:50] [ERROR:gl_display.cc(767)] eglInitialize D3D11 failed with error EGL_NOT_INITIALIZED, trying next display type
        [2026-07-05 05:54:50] [ERROR:gl_display.cc(767)] eglInitialize D3D9 failed with error EGL_NOT_INITIALIZED
        [2026-07-05 05:54:50] [ERROR:gl_display.cc(801)] Initialization of all EGL display types failed.
        [2026-07-05 05:54:50] [ERROR:viz_main_impl.cc(166)] Exiting GPU process due to errors during initialization
        """.write(to: logDirectory.appending(path: "webhelper_gpu.txt"), atomically: true, encoding: .utf8)

        let issue = SteamLaunchDiagnosticsReporter().detectSteamWebHelperRenderingFailure(
            in: steamDirectory,
            since: Date(timeIntervalSince1970: 0)
        )

        XCTAssertNotNil(issue)
        XCTAssertTrue(issue?.webHelperGPUTail.joined(separator: "\n").contains("Initialization of all EGL display types failed") == true)
    }

    func testSteamLaunchDiagnosticsDetectsInvalidReuseAsBlackScreenSignature() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamInvalidReuse-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let steamDirectory = temporaryRoot.appending(path: "Steam", directoryHint: .isDirectory)
        let logDirectory = steamDirectory.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try """
        [2026-07-05 00:00:00] invalid reuse after initialization failure
        """.write(to: logDirectory.appending(path: "webhelper_gpu.txt"), atomically: true, encoding: .utf8)
        try """
        CreateBrowser PopupHTMLWindow (-2147483648, -2147483648) 0x0
        BrowserReady
        """.write(to: logDirectory.appending(path: "steamui_html.txt"), atomically: true, encoding: .utf8)
        try """
        WaitingForCredentials
        UI Request: connect
        """.write(to: logDirectory.appending(path: "steamui_login.txt"), atomically: true, encoding: .utf8)

        let issue = SteamLaunchDiagnosticsReporter().detectSteamWebHelperRenderingFailure(
            in: steamDirectory,
            since: Date(timeIntervalSince1970: 0)
        )

        XCTAssertNotNil(issue)
        XCTAssertTrue(
            issue?.webHelperGPUTail.joined(separator: "\n")
                .contains("invalid reuse after initialization failure") == true
        )
    }

    func testLaunchSteamIgnoresStaleWebHelperRenderingFailureFromPreviousRun() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamLaunchRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let pathManager = PathManager()
        try pathManager.configureRoot(temporaryRoot)
        let steamManager = makeSteamManager(pathManager: pathManager)
        let prefix = try pathManager.url(for: .steamSharedPrefix)
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let runtimeRoot = temporaryRoot.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let launcherDirectory = runtimeRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let launcher = launcherDirectory.appending(path: "wine")
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try createSteamWindowsSystemDirectories(in: prefix)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try writeD3DMetalRenderer(at: renderer)
        try writeSteamRuntimeDependencies(wineRoot: wineRoot)
        try Data("steam".utf8).write(to: steamDirectory.appending(path: "steam.exe"))
        try """
        #!/bin/sh
        \(steamRegistryRecordingShellPreamble())
        if [ "$1" = "wineserver" ]; then
          exit 0
        fi
        log_dir="$WINEPREFIX/drive_c/Program Files (x86)/Steam/logs"
        mkdir -p "$log_dir"
        cat > "$log_dir/webhelper_gpu.txt" <<'LOG'
        [2000-01-01 00:00:00] eglInitialize D3D11 failed with error EGL_NOT_INITIALIZED
        [2000-01-01 00:00:00] Internal Vulkan error (-9)
        [2000-01-01 00:00:00] GL implementation parts: (gl=disabled,angle=none)
        [2000-01-01 00:00:00] GPU process crashed too many times with SwiftShader
        LOG
        touch "$log_dir/webhelper_gpu.txt"
        cat > "$log_dir/steamui_html.txt" <<'LOG'
        CreateBrowser PopupHTMLWindow (-2147483648, -2147483648) 0x0
        BrowserReady
        LOG
        cat > "$log_dir/steamui_login.txt" <<'LOG'
        WaitingForCredentials
        UI Request: connect
        LOG
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try await applySteamLaunchPolicy(steamManager: steamManager, prefix: prefix, launcher: launcher)

        let result = try await steamManager.launchSteam(
            runtimeExecutable: launcher,
            verificationMode: .conformance,
            rendererPolicy: .d3dMetal
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.processExitCode, 0)
        XCTAssertEqual(result.forgePlayStatusCode, SteamManager.steamUIStartupFailureExitCode)
        XCTAssertNotNil(result.diagnosticLog)
    }

    private func writeManifest(
        appId: String,
        name: String,
        installDir: String,
        stateFlags: Int = 4,
        sizeOnDisk: Int64 = 8,
        lastUpdated: Int64 = 1_781_744_000,
        createsInstallDirectory: Bool = true,
        to url: URL
    ) throws {
        try """
        "AppState"
        {
            "appid" "\(appId)"
            "name" "\(name)"
            "installdir" "\(installDir)"
            "StateFlags" "\(stateFlags)"
            "SizeOnDisk" "\(sizeOnDisk)"
            "LastUpdated" "\(lastUpdated)"
        }
        """.write(to: url, atomically: true, encoding: .utf8)
        if createsInstallDirectory,
           url.deletingLastPathComponent().lastPathComponent.lowercased() == "steamapps",
           let normalizedInstallDir = SteamGameIdentityPolicy.installDirectoryName(installDir) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent()
                    .appending(path: "common", directoryHint: .isDirectory)
                    .appending(path: normalizedInstallDir, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
    }

    private func steamRegistryRecordingShellPreamble() -> String {
        #"""
        if [ "$1" = "$WINEPREFIX" ]; then
          shift
        fi
        if [ "$1" = "cmd" ] && [ "$2" = "/c" ]; then
          shift 2
          command="$*"
          if printf '%s' "$command" | grep -q 'reg delete '; then
            section="$(printf '%s' "$command" | sed -n 's/^.*reg query "\([^"]*\)".*$/\1/p')"
            value="$(printf '%s' "$command" | sed -n 's/^.*\/v \([^ ]*\).*$/\1/p')"
            value="$(printf '%s' "$value" | sed 's/^"//; s/"$//')"
            if [ -z "$value" ]; then
              value="$(printf '%s' "$command" | sed -n 's/^.*\/v "\([^"]*\)".*$/\1/p')"
            fi
            registry_file="$WINEPREFIX/user.reg"
            case "$section" in
              HKLM\\*)
                registry_file="$WINEPREFIX/system.reg"
                section="${section#HKLM\\}"
                ;;
              HKCU\\*)
                section="${section#HKCU\\}"
                ;;
              *)
                exit 0
                ;;
            esac
            if [ -n "$section" ] && [ -n "$value" ] && [ -f "$registry_file" ]; then
              awk -v value="\"$value\"=" '
                index($0, value) == 1 { next }
                { print }
              ' "$registry_file" > "$registry_file.tmp" &&
                mv "$registry_file.tmp" "$registry_file"
            fi
            exit 0
          fi
        fi
        if [ "$1" = "reg" ] && [ "$2" = "delete" ]; then
          section="$3"
          value=""
          shift 3
          while [ "$#" -gt 0 ]; do
            case "$1" in
              /v)
                value="$2"
                shift 2
                ;;
              *)
                shift
                ;;
            esac
          done
          registry_file="$WINEPREFIX/user.reg"
          case "$section" in
            HKLM\\*)
              registry_file="$WINEPREFIX/system.reg"
              section="${section#HKLM\\}"
              ;;
            HKCU\\*)
              section="${section#HKCU\\}"
              ;;
            *)
              exit 1
              ;;
          esac
          if [ -z "$section" ] || [ -z "$value" ] || [ ! -f "$registry_file" ]; then
            exit 1
          fi
          FORGEPLAY_REGISTRY_TARGET="$section" \
          awk -v value="\"$value\"=" '
            BEGIN { target = ENVIRON["FORGEPLAY_REGISTRY_TARGET"] }
            function normalized(input) {
              gsub(/\\\\/, "\\", input)
              return input
            }
            /^\[/ {
              registry_section = $0
              sub(/^\[/, "", registry_section)
              sub(/\][[:space:]].*$/, "", registry_section)
              sub(/\]$/, "", registry_section)
              in_target = normalized(registry_section) == normalized(target)
            }
            in_target && index($0, value) == 1 {
              removed = 1
              next
            }
            { print }
            END { if (!removed) exit 2 }
          ' "$registry_file" > "$registry_file.tmp" &&
            mv "$registry_file.tmp" "$registry_file"
          exit $?
        fi
        if [ "$1" = "reg" ] && [ "$2" = "add" ]; then
          section="$3"
          value=""
          data=""
          type=""
          shift 3
          while [ "$#" -gt 0 ]; do
            case "$1" in
              /v)
                value="$2"
                shift 2
                ;;
              /t)
                type="$2"
                shift 2
                ;;
              /d)
                data="$2"
                shift 2
                ;;
              *)
                shift
                ;;
              esac
          done
          mkdir -p "$WINEPREFIX"
          registry_file="$WINEPREFIX/user.reg"
          if printf '%s' "$section" | grep -q '^HKLM\\'; then
            registry_file="$WINEPREFIX/system.reg"
            section="$(printf '%s' "$section" | sed 's/^HKLM\\//')"
          elif printf '%s' "$section" | grep -q '^HKCU\\'; then
            section="$(printf '%s' "$section" | sed 's/^HKCU\\//')"
          fi
          if [ "$type" = "REG_DWORD" ]; then
            if [ "$data" = "1" ]; then
              data="dword:00000001"
            elif [ "$data" = "0" ]; then
              data="dword:00000000"
            else
              data="dword:$data"
            fi
            value_line="\"$value\"=$data"
          elif [ "$type" = "REG_MULTI_SZ" ]; then
            value_line="\"$value\"=str(7):\"$data\\0\""
          else
            value_line="\"$value\"=\"$data\""
          fi
          {
            printf '\n%s\n' "[$section]"
            printf '%s\n' "$value_line"
          } >> "$registry_file"
          exit 0
        fi
        """#
    }

    private func writeSteamRuntimeDependencies(wineRoot: URL) throws {
        let runtimeLib = wineRoot.appending(path: "lib", directoryHint: .isDirectory)
        let runtimeBin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let wineBinary = runtimeBin.appending(path: "wine.bin")
        let wineServer = runtimeBin.appending(path: "wineserver")
        let icdDirectory = wineRoot.appending(path: "etc/vulkan/icd.d", directoryHint: .isDirectory)
        let wineInf = wineRoot.appending(path: "share/wine/wine.inf")
        let wineWindowsModules = wineRoot.appending(
            path: "lib/wine/x86_64-windows",
            directoryHint: .isDirectory
        )
        let wineboot = wineWindowsModules.appending(path: "wineboot.exe")
        try FileManager.default.createDirectory(at: runtimeLib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimeBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: icdDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: wineInf.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: wineboot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let wineUnixModules = runtimeLib.appending(
            path: "wine/x86_64-unix",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: wineUnixModules,
            withIntermediateDirectories: true
        )
        try Data().write(to: runtimeLib.appending(path: "libgnutls.30.dylib"))
        try Data().write(to: runtimeLib.appending(path: "libfreetype.6.dylib"))
        try Data().write(to: runtimeLib.appending(path: "libvulkan.1.dylib"))
        try Data().write(to: runtimeLib.appending(path: "libMoltenVK.dylib"))
        try Data("test wine identity\n".utf8).write(to: wineInf)
        try Data("test wineboot identity\n".utf8).write(to: wineboot)
        try Data("test ntdll identity\n".utf8).write(to: wineUnixModules.appending(path: "ntdll.so"))
        for (name, payload) in [
            ("xinput1_4.dll", "test xinput 1.4 bridge\n"),
            ("winebus.sys", "test winebus bridge\n"),
            ("hidclass.sys", "test hidclass bridge\n")
        ] {
            try Data(payload.utf8).write(to: wineWindowsModules.appending(path: name))
        }
        let steamWebHelperArgumentPolicyMarkers = [
            SteamWebHelperLaunchPolicy.argumentTargetEnvironmentKey,
            SteamWebHelperLaunchPolicy.argumentAppendEnvironmentKey,
            SteamWebHelperLaunchPolicy.argumentRootOnlyEnvironmentKey
        ].joined(separator: "\0")
        for architecture in ["i386-windows", "x86_64-windows"] {
            let kernelbase = runtimeLib.appending(
                path: "wine/\(architecture)/kernelbase.dll"
            )
            try FileManager.default.createDirectory(
                at: kernelbase.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(steamWebHelperArgumentPolicyMarkers.utf8).write(
                to: kernelbase
            )
        }
        if !FileManager.default.fileExists(atPath: wineBinary.path) {
            try #"""
            #!/bin/sh
            exec "$(dirname "$0")/wine" "$@"
            """#.write(
                to: wineBinary,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: wineBinary.path
            )
        }
        if !FileManager.default.fileExists(atPath: wineServer.path) {
            try #"""
            #!/bin/sh
            exec "$(dirname "$0")/wine" wineserver "$@"
            """#.write(
                to: wineServer,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: wineServer.path
            )
        }
        try #"{"ICD":{"library_path":"../../lib/libMoltenVK.dylib","api_version":"1.4.0"}}"#
            .write(to: icdDirectory.appending(path: "MoltenVK_icd.json"), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func createSteamWindowsSystemDirectories(in prefix: URL) throws -> (system32: URL, syswow64: URL) {
        let system32 = prefix.appending(path: "drive_c/windows/system32", directoryHint: .isDirectory)
        let syswow64 = prefix.appending(path: "drive_c/windows/syswow64", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syswow64, withIntermediateDirectories: true)
        for registryName in ["user.reg", "system.reg"] {
            let registry = prefix.appending(path: registryName)
            if !FileManager.default.fileExists(atPath: registry.path) {
                try "WINE REGISTRY Version 2\n".write(to: registry, atomically: true, encoding: .utf8)
            }
        }
        return (system32, syswow64)
    }

    private func writeD3DMetalRenderer(at renderer: URL) throws {
        let external = renderer.appending(path: "external/D3DMetal.framework", directoryHint: .isDirectory)
        let frameworkResources = external.appending(path: "Resources", directoryHint: .isDirectory)
        let unixModules = renderer.appending(path: "wine/x86_64-unix", directoryHint: .isDirectory)
        let windows64Modules = renderer.appending(path: "wine/x86_64-windows", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frameworkResources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unixModules, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: windows64Modules, withIntermediateDirectories: true)
        try Data().write(to: external.appending(path: "D3DMetal"))
        try Data("test D3DMetal shared library\n".utf8).write(
            to: renderer.appending(path: "external/libd3dshared.dylib")
        )
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>D3DMetal</string>
            <key>CFBundleShortVersionString</key>
            <string>4.0</string>
            <key>CFBundleVersion</key>
            <string>4.0b1</string>
        </dict>
        </plist>
        """.write(
            to: frameworkResources.appending(path: "Info.plist"),
            atomically: true,
            encoding: .utf8
        )
        for resourceName in [
            "default.metallib",
            "libdxccontainer.dylib",
            "libdxcompiler.dylib",
            "libdxilconv.dylib",
            "libmetalirconverter.dylib"
        ] {
            try Data().write(to: frameworkResources.appending(path: resourceName))
        }
        for relativePath in D3DMetalRendererPayloadContract.sharedUnixModuleRelativePaths {
            try FileManager.default.createSymbolicLink(
                atPath: renderer.appending(path: relativePath).path,
                withDestinationPath: D3DMetalRendererPayloadContract.sharedUnixModuleLinkTarget
            )
        }
        for moduleName in [
            "d3d10",
            "d3d11",
            "d3d12",
            "dxgi",
            "nvapi64",
            "nvngx-on-metalfx"
        ] {
            try Data("test D3DMetal \(moduleName)\n".utf8).write(
                to: windows64Modules.appending(path: "\(moduleName).dll")
            )
        }
        try Data(
            contentsOf: windows64Modules.appending(path: "nvapi64.dll")
        ).write(
            to: windows64Modules.appending(path: "nvapi.dll")
        )

        let rendererRoot = renderer.deletingLastPathComponent()
        try writeD9VKRenderer(at: rendererRoot.appending(path: "d9vk", directoryHint: .isDirectory))
        try writeDXMTRenderer(at: rendererRoot.appending(path: "dxmt", directoryHint: .isDirectory))
    }

    private func writeD9VKRenderer(at renderer: URL) throws {
        for architecture in ["x86_64-windows", "i386-windows"] {
            let modules = renderer.appending(path: "wine/\(architecture)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
            try Data("d9vk d3d9".utf8).write(to: modules.appending(path: "d3d9.dll"))
        }
    }

    private func writeDXMTRenderer(at renderer: URL) throws {
        let unixModules = renderer.appending(path: "wine/x86_64-unix", directoryHint: .isDirectory)
        let windows64Modules = renderer.appending(path: "wine/x86_64-windows", directoryHint: .isDirectory)
        let windows32Modules = renderer.appending(path: "wine/i386-windows", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unixModules, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: windows64Modules, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: windows32Modules, withIntermediateDirectories: true)
        try Data("dxmt winemetal unix".utf8).write(to: unixModules.appending(path: "winemetal.so"))
        for directory in [windows64Modules, windows32Modules] {
            try Data("dxmt d3d10core".utf8).write(to: directory.appending(path: "d3d10core.dll"))
            try Data("dxmt d3d11".utf8).write(to: directory.appending(path: "d3d11.dll"))
            try Data("dxmt dxgi".utf8).write(to: directory.appending(path: "dxgi.dll"))
            try Data("dxmt winemetal".utf8).write(to: directory.appending(path: "winemetal.dll"))
        }
    }

    private func writeDXMTMacDriverBridge(wineRoot: URL) throws {
        let unixModules = wineRoot.appending(path: "lib/wine/x86_64-unix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unixModules, withIntermediateDirectories: true)
        try Data("_macdrv_functions".utf8).write(to: unixModules.appending(path: "winemac.so"))
    }

    private func writeSteamLibraryFolderIdentity(
        contentID: String,
        label: String = "",
        to libraryRoot: URL
    ) throws {
        try """
        "libraryfolder"
        {
            "contentid" "\(contentID)"
            "label" "\(label)"
        }
        """.write(
            to: libraryRoot.appending(path: "libraryfolder.vdf"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func legacyForgePlayStableContentID(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash == 0 ? 1 : hash)
    }

    private func applySteamLaunchPolicy(
        steamManager: SteamManager,
        prefix: URL,
        launcher: URL,
        rendererPolicy: SteamRendererPolicyPreference = .d3dMetal
    ) async throws {
        _ = try await steamManager.applySteamClientCompatibilityProfile(
            runtimeExecutable: launcher,
            prefix: prefix
        )
        try await steamManager.restoreSteamRendererBridgeModules(
            prefix: prefix,
            runtimeExecutable: launcher
        )
        let inspection = steamManager.inspectSteamRendererPolicy(
            prefix: prefix,
            runtimeExecutable: launcher,
            selection: SteamRendererPolicyManager.selection(for: rendererPolicy)
        )
        let userRegistryContents = (try? String(
            contentsOf: prefix.appending(path: "user.reg"),
            encoding: .utf8
        )) ?? "<missing user.reg>"
        XCTAssertEqual(
            inspection.status,
            .ok,
            [
                inspection.userMessage,
                "missingProfileOverrides=\(inspection.missingProfileOverrides.joined(separator: ","))",
                "staleProfileOverrides=\(inspection.staleProfileOverrides.joined(separator: ","))",
                "user.reg=\(userRegistryContents)"
            ].joined(separator: "\n")
        )
    }

    private func writeRendererWith64And32BitWindowsModules(
        at renderer: URL,
        externalFrameworkName: String?,
        modulePayloads64: [String: String],
        modulePayloads32: [String: String]
    ) throws {
        let windows64Modules = renderer.appending(path: "wine/x86_64-windows", directoryHint: .isDirectory)
        let windows32Modules = renderer.appending(path: "wine/i386-windows", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: windows64Modules, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: windows32Modules, withIntermediateDirectories: true)
        if let externalFrameworkName {
            let external = renderer.appending(path: "external/\(externalFrameworkName)", directoryHint: .isDirectory)
            let unixModules = renderer.appending(path: "wine/x86_64-unix", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: unixModules, withIntermediateDirectories: true)
            try Data().write(to: external.appending(path: externalFrameworkName.replacingOccurrences(of: ".framework", with: "")))
            try Data().write(to: renderer.appending(path: "external/libd3dshared.dylib"))
            try Data().write(to: unixModules.appending(path: "d3d9.so"))
            try Data().write(to: unixModules.appending(path: "d3d11.so"))
            try Data().write(to: unixModules.appending(path: "dxgi.so"))
        }
        for (name, payload) in modulePayloads64 {
            try Data(payload.utf8).write(to: windows64Modules.appending(path: name))
        }
        for (name, payload) in modulePayloads32 {
            try Data(payload.utf8).write(to: windows32Modules.appending(path: name))
        }
    }

    private func steamLogDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
        return try XCTUnwrap(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )))
    }

    private func rendererDiagnostic(
        processObservation: SteamProcessObservationReadResult,
        executable: String,
        processID: Int32
    ) throws -> SteamGameLaunchDiagnostic {
        let startedAt = try steamLogDate(
            year: 2026,
            month: 7,
            day: 17,
            hour: 5,
            minute: 10,
            second: 0
        )
        return try XCTUnwrap(SteamGameLaunchDiagnosticAnalyzer.analyze(
            gameProcessLines: [
                "[2026-07-17 05:10:00] AppID 990001 adding PID \(processID) " +
                    "as a tracked process \"\"\(executable)\"\""
            ],
            consoleLines: [],
            processObservation: processObservation,
            since: startedAt.addingTimeInterval(-1),
            now: startedAt.addingTimeInterval(2)
        ))
    }

    private func diagnosticSectionLineCount(
        named startLabel: String,
        before endLabel: String,
        in diagnostics: String
    ) -> Int {
        let lines = diagnostics
            .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map(String.init)
        guard let startIndex = lines.firstIndex(of: startLabel),
              let endIndex = lines[startIndex...].firstIndex(of: endLabel) else {
            return Int.max
        }
        return lines[lines.index(after: startIndex)..<endIndex]
            .filter { !$0.isEmpty }
            .count
    }

    /// Most lifecycle fixtures in this file model a Runtime already accepted by
    /// WindowsRuntimeService. The live bundled-Runtime test intentionally keeps
    /// SafeProcessRunner's production validator instead.
    private func makeCuratedRuntimeRunner(
        runtimeLaunchObjectIdentityProvider:
            @escaping SafeProcessRunner.RuntimeLaunchObjectIdentityProvider = {
                _ in nil
            }
    ) -> SafeProcessRunner {
        SafeProcessRunner(
            managedWineProcessJournalEnabled: false,
            managedWineRuntimeFingerprintResolver: {
                _ in String(repeating: "a", count: 64)
            },
            runtimeLaunchObjectIdentityProvider:
                runtimeLaunchObjectIdentityProvider,
            managedWineChildSynchronizationReadbackProvider: { processIdentifier in
                guard processIdentifier > 0 else {
                    throw SafeProcessRunnerError.invalidPrefixSynchronizationProfile(
                        URL(fileURLWithPath: "/proc/\(processIdentifier)/environment")
                    )
                }
                return ManagedWineChildSynchronizationReadback(
                    processIdentifier: processIdentifier,
                    selection: .automatic,
                    backend: .server
                )
            },
            windowsRuntimeValidator: { _, _ in }
        )
    }

}
