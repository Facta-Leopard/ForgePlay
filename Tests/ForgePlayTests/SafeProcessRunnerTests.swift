import CryptoKit
import Darwin
import Security
import XCTest
@testable import ForgePlay

private struct SafeProcessRunnerTestSupplementalRendererAuthenticator:
    AppleSupplementalRendererAuthenticating {
    typealias Handler = @Sendable (URL, FileManager) throws -> Void

    private let handler: Handler

    init(handler: @escaping Handler = { _, _ in }) {
        self.handler = handler
    }

    func authenticate(
        rendererRoot: URL,
        fileManager: FileManager
    ) throws {
        try handler(rendererRoot, fileManager)
    }
}

private final class ManagedWineReadbackTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPrimaryProcessIdentifier: pid_t?
    private var storedLoaderProcessIdentifier: pid_t?
    private var storedReadbackProcessIdentifiers: [pid_t] = []

    func recordReadback(processIdentifier: pid_t) {
        lock.withLock {
            storedReadbackProcessIdentifiers.append(processIdentifier)
        }
    }

    func recordPrimary(processIdentifier: pid_t) {
        lock.withLock {
            storedPrimaryProcessIdentifier = processIdentifier
        }
    }

    func recordLoader(processIdentifier: pid_t) {
        lock.withLock {
            storedLoaderProcessIdentifier = processIdentifier
        }
    }

    var primaryProcessIdentifier: pid_t? {
        lock.withLock { storedPrimaryProcessIdentifier }
    }

    var loaderProcessIdentifier: pid_t? {
        lock.withLock { storedLoaderProcessIdentifier }
    }

    var readbackProcessIdentifiers: [pid_t] {
        lock.withLock { storedReadbackProcessIdentifiers }
    }
}

/// Installs the complete authenticated Runtime envelope around a synthetic
/// launcher used by process-boundary tests. Production launch validation now
/// retains every required core object, so a lone shell script is no longer a
/// truthful stand-in for a Runtime that has already passed curation.
func installAuthenticatedRuntimePayloadFixture(for executable: URL) throws {
    let executable = executable.standardizedFileURL
    let executableDirectory = executable.deletingLastPathComponent()
    let runtimeRoot: URL
    if executableDirectory.lastPathComponent == "bin",
       executableDirectory.deletingLastPathComponent().lastPathComponent == "wine" {
        runtimeRoot = executableDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    } else {
        runtimeRoot = executableDirectory
    }
    try installAuthenticatedRuntimePayloadFixture(
        at: runtimeRoot,
        executable: executable
    )
}

func installAuthenticatedRuntimePayloadFixtureIfSafe(for executable: URL) throws {
    guard FileSystemItemPolicy.isRegularNonSymlinkFile(executable) else {
        return
    }
    try installAuthenticatedRuntimePayloadFixture(for: executable)
}

func installAuthenticatedRuntimePayloadFixture(
    at runtimeRoot: URL,
    executable: URL
) throws {
    let fileManager = FileManager.default
    let runtimeRoot = runtimeRoot.standardizedFileURL
    let executable = executable.standardizedFileURL
    try fileManager.createDirectory(
        at: runtimeRoot,
        withIntermediateDirectories: true
    )

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func writeIfMissing(_ data: Data, to url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    var corePayloads: [String: String] = [:]
    for relativePath in RuntimeManifest.requiredCorePayloadPaths.sorted() {
        let url = runtimeRoot.appending(path: relativePath)
        let fixtureData: Data
        if relativePath.hasPrefix("wine/bin/") ||
            relativePath == "wine/lib/wine/x86_64-unix/wine" {
            fixtureData = Data("#!/bin/sh\nexit 0\n".utf8)
        } else {
            fixtureData = Data("ForgePlay authenticated Runtime fixture: \(relativePath)\n".utf8)
        }
        try writeIfMissing(fixtureData, to: url)
        try FileSystemItemPolicy.requireRegularNonSymlinkFile(url)
        if relativePath.hasPrefix("wine/bin/") ||
            relativePath == "wine/lib/wine/x86_64-unix/wine" {
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        }
        corePayloads[relativePath] = sha256(try Data(contentsOf: url))
    }

    let wineInf = runtimeRoot.appending(path: "wine/share/wine/wine.inf")
    let wineboot = runtimeRoot.appending(
        path: "wine/lib/wine/x86_64-windows/wineboot.exe"
    )
    try writeIfMissing(Data("ForgePlay test wine.inf\n".utf8), to: wineInf)
    try writeIfMissing(Data("ForgePlay test wineboot.exe\n".utf8), to: wineboot)
    try FileSystemItemPolicy.requireRegularNonSymlinkFile(executable)
    try FileSystemItemPolicy.requireRegularNonSymlinkFile(wineInf)
    try FileSystemItemPolicy.requireRegularNonSymlinkFile(wineboot)

    let gstreamerRoot = runtimeRoot.appending(
        path: "wine/gstreamer",
        directoryHint: .isDirectory
    )
    let gstreamerPluginRoot = gstreamerRoot.appending(
        path: "lib/gstreamer-1.0",
        directoryHint: .isDirectory
    )
    try fileManager.createDirectory(
        at: gstreamerPluginRoot,
        withIntermediateDirectories: true
    )
    let defaultPlugin = gstreamerPluginRoot.appending(
        path: "libforgeplay-test-plugin.dylib"
    )
    let existingPlugins = (fileManager.enumerator(
        at: gstreamerRoot,
        includingPropertiesForKeys: nil
    )?.allObjects as? [URL] ?? []).filter {
        $0.pathExtension == "dylib" &&
            FileSystemItemPolicy.isRegularNonSymlinkFile($0)
    }
    if existingPlugins.isEmpty {
        try writeIfMissing(
            Data("ForgePlay test GStreamer plugin\n".utf8),
            to: defaultPlugin
        )
    }
    let plugins = (fileManager.enumerator(
        at: gstreamerRoot,
        includingPropertiesForKeys: nil
    )?.allObjects as? [URL] ?? []).filter {
        $0.pathExtension == "dylib" &&
            FileSystemItemPolicy.isRegularNonSymlinkFile($0)
    }.sorted { $0.path < $1.path }
    let rootPrefix = runtimeRoot.path + "/"
    let hostSupportPayload: [[String: Any]] = try plugins.map { plugin in
        let pluginPath = plugin.standardizedFileURL.path
        guard pluginPath.hasPrefix(rootPrefix) else {
            throw FileSystemItemPolicyError.notRegularNonSymlinkFile(plugin)
        }
        let digest = sha256(try Data(contentsOf: plugin))
        return [
            "contentHashAlgorithm": "sha256",
            "contentSHA256": digest,
            "consumptionHashAlgorithm":
                RuntimeManifest.currentCorePayloadHashAlgorithm,
            "consumptionSHA256": digest,
            "path": String(pluginPath.dropFirst(rootPrefix.count)),
            "type": "file"
        ]
    }
    let hostSupportPayloadData = try JSONSerialization.data(
        withJSONObject: hostSupportPayload,
        options: [.sortedKeys]
    )
    let hostSupportPayloadFingerprint = sha256(hostSupportPayloadData)
    let sbomData = try JSONSerialization.data(
        withJSONObject: [
            "schemaVersion": RuntimeManifest.currentHostSupportSBOMSchemaVersion,
            "runtimeIdentifier": "forgeplay.tests.authenticated-runtime",
            "payloadFingerprint": hostSupportPayloadFingerprint,
            "hostSupportPayload": hostSupportPayload
        ],
        options: [.prettyPrinted, .sortedKeys]
    )
    let sbom = runtimeRoot.appending(path: "RuntimeSBOM.json")
    try sbomData.write(to: sbom, options: .atomic)

    let wineInfSHA256 = sha256(try Data(contentsOf: wineInf))
    let winebootSHA256 = sha256(try Data(contentsOf: wineboot))
    let launcherSHA256 = sha256(try Data(contentsOf: executable))
    let corePayloadFingerprint = RuntimeManifest.corePayloadFingerprint(
        corePayloads
    )
    let prefixCompatibilityFingerprint =
        RuntimeManifest.prefixCompatibilityFingerprint(
            wineVersion: "ForgePlayTests",
            architecture: WinePrefixDefaults.architecture,
            wineInfSHA256: wineInfSHA256,
            winebootSHA256: winebootSHA256
        )
    let manifest = RuntimeManifest(
        schemaVersion: RuntimeManifest.currentSchemaVersion,
        runtimeIdentifier: "forgeplay.tests.authenticated-runtime",
        wineVersion: "ForgePlayTests",
        architecture: WinePrefixDefaults.architecture,
        sourceTreeSHA256: nil,
        patchSetSHA256: nil,
        runnerLauncherSHA256: launcherSHA256,
        wineInfSHA256: wineInfSHA256,
        winebootSHA256: winebootSHA256,
        prefixCompatibilityFingerprint: prefixCompatibilityFingerprint,
        runnerBuildFingerprint: RuntimeManifest.runnerBuildFingerprint(
            sourceTreeSHA256: nil,
            patchSetSHA256: nil,
            runnerLauncherSHA256: launcherSHA256,
            prefixCompatibilityFingerprint: prefixCompatibilityFingerprint,
            hostSupportPayloadFingerprint: hostSupportPayloadFingerprint,
            corePayloadFingerprint: corePayloadFingerprint
        ),
        hostSupportSBOMPath: "RuntimeSBOM.json",
        hostSupportSBOMSHA256: sha256(sbomData),
        hostSupportPayloadFingerprint: hostSupportPayloadFingerprint,
        corePayloadHashAlgorithm:
            RuntimeManifest.currentCorePayloadHashAlgorithm,
        corePayloadSHA256: corePayloads,
        corePayloadFingerprint: corePayloadFingerprint
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(
        to: runtimeRoot.appending(path: "RuntimeManifest.json"),
        options: .atomic
    )
}

final class SafeProcessRunnerTests: XCTestCase {
    func testPrelaunchCompatibilityDefaultsToSystemKeyboardMapping() throws {
        let defaultSelection = SteamPrelaunchCompatibilitySelection(
            rendererSelection: .d3dMetal,
            networkSelection: .standard,
            audioInputSelection: .enabled
        )
        let explicitLegacyPreference = try KeyboardMappingPreference(
            preset: .windowsFriendly
        )
        let explicitLegacySelection = SteamPrelaunchCompatibilitySelection(
            rendererSelection: .d3dMetal,
            networkSelection: .standard,
            audioInputSelection: .enabled,
            keyboardMapping: explicitLegacyPreference
        )

        XCTAssertEqual(defaultSelection.keyboardMapping.preset, .systemDefault)
        XCTAssertEqual(
            explicitLegacySelection.keyboardMapping.preset,
            .windowsFriendly
        )
    }

    func testGameModeHostEvidenceSelectsOnlyCurrentRunOwnedDarwinProcesses() {
        let registeredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let runIdentifier = "3D79C3A0-8D67-4B35-BA7E-644660A1F150"
        let data = Data((
            """
            {"schema_version":1,"producer":"game-mode-process-host","event_code":"wine_main_entered","recorded_at_unix_milliseconds":1800000001000,"darwin_pid":42001,"process_started_at_unix_microseconds":1800000000500000,"run_identifier":"3d79c3a0-8d67-4b35-ba7e-644660a1f150"}
            {"schema_version":1,"producer":"game-mode-process-host","event_code":"host_started","recorded_at_unix_milliseconds":1800000001000,"darwin_pid":42002}
            {"schema_version":1,"producer":"game-mode-process-host","event_code":"prefix_execution_lease_acquired","recorded_at_unix_milliseconds":1800000001000,"darwin_pid":42003,"run_identifier":"00000000-0000-0000-0000-000000000000"}
            {"schema_version":1,"producer":"game-mode-process-host","event_code":"inherited_execution_verified","recorded_at_unix_milliseconds":1799999900000,"darwin_pid":42004,"run_identifier":"3d79c3a0-8d67-4b35-ba7e-644660a1f150"}
            """
        ).utf8)

        XCTAssertEqual(
            SafeProcessRunner.gameModeHostEvidenceProcessIDs(
                in: data,
                runIdentifier: runIdentifier,
                registeredAt: registeredAt,
                observedAt: registeredAt.addingTimeInterval(2)
            ),
            [42_001]
        )
    }

    func testLegacyGameModeEvidenceWithoutKernelStartIdentityCannotAuthorizeSignal() {
        let registeredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let runIdentifier = "3D79C3A0-8D67-4B35-BA7E-644660A1F150"
        let data = Data((
            """
            {"schema_version":1,"producer":"game-mode-process-host","event_code":"wine_main_entered","recorded_at_unix_milliseconds":1800000001000,"darwin_pid":42001,"run_identifier":"3d79c3a0-8d67-4b35-ba7e-644660a1f150"}
            """
        ).utf8)

        XCTAssertEqual(
            SafeProcessRunner.gameModeHostEvidenceProcessIDs(
                in: data,
                runIdentifier: runIdentifier,
                registeredAt: registeredAt,
                observedAt: registeredAt.addingTimeInterval(2)
            ),
            []
        )
    }

    func testManagedWineSessionRegistryPreservesEveryDistinctPrefix() {
        let registry = ManagedWineSessionRegistry()
        registry.record(URL(fileURLWithPath: "/tmp/ForgePlay-A/Prefixes/SteamShared"))
        registry.record(URL(fileURLWithPath: "/tmp/ForgePlay-B/Prefixes/SteamShared"))
        registry.record(URL(fileURLWithPath: "/tmp/ForgePlay-A/Prefixes/SteamShared"))

        XCTAssertEqual(
            registry.prefixURLs.map(\.path),
            [
                "/tmp/ForgePlay-A/Prefixes/SteamShared",
                "/tmp/ForgePlay-B/Prefixes/SteamShared"
            ]
        )
    }

    func testManagedWineSessionRegistryForgetsPrefixAfterConfirmedCleanup() {
        let registry = ManagedWineSessionRegistry()
        let canonicalPrefix = URL(
            fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared"
        )
        let migrationStagingPrefix = URL(
            fileURLWithPath:
                "/tmp/ForgePlay/Prefixes/.SteamShared.runtime-migration-staging-fixture"
        )
        registry.record(canonicalPrefix)
        registry.record(migrationStagingPrefix)

        XCTAssertTrue(
            registry.completeSessions(for: migrationStagingPrefix).isEmpty
        )

        XCTAssertEqual(registry.prefixURLs.map(\.path), [
            canonicalPrefix.path
        ])
    }

    func testPrefixReplacementQuiescenceRequiresRetiredSessionsAndNoTracker() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayPrefixQuiescence-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        let registry = ManagedWineSessionRegistry()
        registry.record(ManagedWineProcessLaunchSession(
            prefixURL: prefix,
            runIdentifier: UUID().uuidString.lowercased(),
            evidenceURL: root.appending(path: "managed-wine.jsonl"),
            runtimeRootURL: root.appending(
                path: "ForgePlayRuntime/wine",
                directoryHint: .isDirectory
            ),
            runtimeFingerprint: String(repeating: "a", count: 64),
            prefixScope: ManagedWineProcessJournal.prefixScope(for: prefix),
            registeredAt: Date()
        ))
        let runner = makeCuratedRuntimeRunner(
            sandboxEnabled: true,
            managedWineProcessJournalEnabled: false,
            managedWineSessionRegistry: registry
        )

        do {
            try await runner.requirePrefixReplacementQuiescence(prefix)
            XCTFail("a registered launch session must block prefix replacement")
        } catch {
            XCTAssertTrue(
                forgePlayTechnicalErrorSummary(error)
                    .contains("launch session(s) remain registered")
            )
        }
        _ = registry.completeSessions(for: prefix)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }
        await runner.trackDetachedProcess(process, for: prefix)
        do {
            try await runner.requirePrefixReplacementQuiescence(prefix)
            XCTFail("retained Foundation ownership must block replacement")
        } catch {
            XCTAssertTrue(
                forgePlayTechnicalErrorSummary(error)
                    .contains("retained process ownership")
            )
        }

        process.terminate()
        process.waitUntilExit()
        try await runner.requirePrefixReplacementQuiescence(prefix)
    }

    func testManagedWineIdentityResolutionWaitsThroughExitReapRace() {
        var livenessProbes: [ManagedWineProcessJournal.ProcessLivenessProbe] = [
            .present,
            .missing
        ]
        var waitCount = 0

        let resolution = ManagedWineProcessJournal
            .resolveProcessIdentityAcrossExitBoundary(
                for: 3_673,
                retryCount: 2,
                retryInterval: 0.025,
                startTimeProvider: { _ in nil },
                livenessProvider: { _ in livenessProbes.removeFirst() },
                wait: { _ in waitCount += 1 }
            )

        XCTAssertEqual(resolution, .exited)
        XCTAssertEqual(waitCount, 1)
        XCTAssertTrue(livenessProbes.isEmpty)
    }

    func testManagedWineIdentityResolutionStillFailsClosedForUnreadableLivePID() {
        var livenessProbeCount = 0
        var waitCount = 0

        let resolution = ManagedWineProcessJournal
            .resolveProcessIdentityAcrossExitBoundary(
                for: 42_001,
                retryCount: 2,
                retryInterval: 0.025,
                startTimeProvider: { _ in nil },
                livenessProvider: { _ in
                    livenessProbeCount += 1
                    return .present
                },
                wait: { _ in waitCount += 1 }
            )

        XCTAssertEqual(resolution, .unavailable)
        XCTAssertEqual(livenessProbeCount, 3)
        XCTAssertEqual(waitCount, 2)
    }

    func testUnreadablePresentJournalPIDRequiresExactUnreapedDescriptorTracker() {
        let prefix = URL(
            fileURLWithPath: "/tmp/ForgePlay/Prefixes/SteamShared",
            isDirectory: true
        )
        let processID: pid_t = 42_001
        let startedAt: UInt64 = 1_800_000_000_123_456
        let descriptorCapability = ManagedProcessSignalTarget(
            processID: processID,
            processStartedAtUnixMicroseconds: startedAt,
            executableURL: URL(fileURLWithPath: "/tmp/Runtime/wine"),
            source: .trackedDescriptorBoundProcess
        )

        XCTAssertTrue(
            SafeProcessRunner
                .exactUnreapedDescriptorLeaderMatchesJournalCandidate(
                    candidateProcessID: processID,
                    candidateProcessStartedAtUnixMicroseconds: startedAt,
                    candidatePrefixURL: prefix,
                    trackedProcessID: processID,
                    trackedPrefixPath: prefix.path,
                    retainedSignalCapability: descriptorCapability,
                    rootWaitObservation: .terminalStateObserved,
                    rootWasActuallyReaped: false
                )
        )
        XCTAssertFalse(
            SafeProcessRunner
                .exactUnreapedDescriptorLeaderMatchesJournalCandidate(
                    candidateProcessID: processID,
                    candidateProcessStartedAtUnixMicroseconds: startedAt,
                    candidatePrefixURL: prefix,
                    trackedProcessID: processID,
                    trackedPrefixPath: prefix.path,
                    retainedSignalCapability: descriptorCapability,
                    rootWaitObservation: .awaitingTerminalState,
                    rootWasActuallyReaped: false
                ),
            "an external unreadable-present PID has no WNOWAIT exit proof and must remain unavailable"
        )
        XCTAssertFalse(
            SafeProcessRunner
                .exactUnreapedDescriptorLeaderMatchesJournalCandidate(
                    candidateProcessID: processID,
                    candidateProcessStartedAtUnixMicroseconds: startedAt + 1,
                    candidatePrefixURL: prefix,
                    trackedProcessID: processID,
                    trackedPrefixPath: prefix.path,
                    retainedSignalCapability: descriptorCapability,
                    rootWaitObservation: .terminalStateObserved,
                    rootWasActuallyReaped: false
                ),
            "a mismatched kernel start identity must never inherit the retained tracker"
        )
        XCTAssertFalse(
            SafeProcessRunner
                .exactUnreapedDescriptorLeaderMatchesJournalCandidate(
                    candidateProcessID: processID,
                    candidateProcessStartedAtUnixMicroseconds: startedAt,
                    candidatePrefixURL: prefix,
                    trackedProcessID: processID,
                    trackedPrefixPath: prefix
                        .deletingLastPathComponent().path,
                    retainedSignalCapability: descriptorCapability,
                    rootWaitObservation: .terminalStateObserved,
                    rootWasActuallyReaped: false
            ),
            "retained ownership from another prefix must not classify this journal row as exited"
        )
        XCTAssertFalse(
            SafeProcessRunner
                .exactUnreapedDescriptorLeaderMatchesJournalCandidate(
                    candidateProcessID: processID,
                    candidateProcessStartedAtUnixMicroseconds: startedAt,
                    candidatePrefixURL: prefix,
                    trackedProcessID: processID,
                    trackedPrefixPath: prefix.path,
                    retainedSignalCapability: descriptorCapability,
                    rootWaitObservation: .failed(ECHILD),
                    rootWasActuallyReaped: false
                ),
            "waitid failure is indeterminate, not a successful WNOWAIT terminal observation"
        )
        XCTAssertFalse(
            SafeProcessRunner
                .exactUnreapedDescriptorLeaderMatchesJournalCandidate(
                    candidateProcessID: processID,
                    candidateProcessStartedAtUnixMicroseconds: startedAt,
                    candidatePrefixURL: prefix,
                    trackedProcessID: processID,
                    trackedPrefixPath: prefix.path,
                    retainedSignalCapability: descriptorCapability,
                    rootWaitObservation: .terminalStateObserved,
                    rootWasActuallyReaped: true
                ),
            "an actually reaped root no longer retains the PID reuse barrier"
        )
    }

    func testResidualDescriptorDiagnosticSeparatesExitObservationFromReaping() {
        let diagnostic = SafeProcessRunner
            .descriptorBoundResidualOwnershipDiagnostic(
                processGroupIdentifier: 42_002,
                groupPresence: "present",
                leaderExitObserved: true,
                leaderWasActuallyReaped: false
            )

        XCTAssertTrue(diagnostic.contains("leaderExitObserved=true"))
        XCTAssertTrue(diagnostic.contains("leaderReaped=false"))
        XCTAssertFalse(diagnostic.contains("leaderReaped=true"))
    }

    func testDescriptorProcessGroupDoesNotTreatZombieOnlyRowsAsActive() {
        XCTAssertFalse(
            DescriptorBoundProcessGroupMemberPolicy
                .isActiveBSDProcessStatus(UInt32(SZOMB))
        )
        XCTAssertTrue(
            DescriptorBoundProcessGroupMemberPolicy
                .isActiveBSDProcessStatus(UInt32(SRUN))
        )
    }

    func testDescriptorProcessGroupEnumerationKeepsTailMemberBeyondTwentyTwoRows() {
        let processIDs = (10_000..<10_022).map(pid_t.init)
        let tailProcessIdentifier = try! XCTUnwrap(processIDs.last)
        var observedCapacity = 0
        var countProbeCount = 0

        let presence = DescriptorBoundProcessGroupMemberPolicy.presence(
            rootProcessIdentifier: 9_999,
            countProvider: {
                countProbeCount += 1
                return (processIDs.count, nil)
            },
            enumerationProvider: { capacity in
                observedCapacity = capacity
                return .init(
                    returnedCount: processIDs.count,
                    processIDs: processIDs,
                    errorCode: nil
                )
            },
            memberStateProvider: { processIdentifier in
                processIdentifier == tailProcessIdentifier
                    ? .active
                    : .exitedOrZombie
            }
        )

        XCTAssertEqual(presence, .present)
        XCTAssertGreaterThanOrEqual(
            observedCapacity,
            processIDs.count + 16,
            "proc_listpgrppids reports PID count, so the full count plus growth slack must be allocated"
        )
        XCTAssertEqual(countProbeCount, 2)
    }

    func testDescriptorProcessGroupEnumerationAcceptsUpperBoundCountEstimate() {
        var enumerationCallCount = 0

        let presence = DescriptorBoundProcessGroupMemberPolicy.presence(
            rootProcessIdentifier: 9_999,
            countProvider: { (757, nil) },
            enumerationProvider: { capacity in
                enumerationCallCount += 1
                XCTAssertGreaterThanOrEqual(capacity, 773)
                return .init(
                    returnedCount: 1,
                    processIDs: [10_000],
                    errorCode: nil
                )
            },
            memberStateProvider: { _ in .active }
        )

        XCTAssertEqual(presence, .present)
        XCTAssertEqual(
            enumerationCallCount,
            1,
            "the nil-buffer count is a capacity estimate, not the exact returned group-row count"
        )
    }

    func testDescriptorProcessGroupEnumerationClassifiesZombieAndUnreadableRows() {
        let allZombie = DescriptorBoundProcessGroupMemberPolicy.presence(
            rootProcessIdentifier: 9_999,
            countProvider: { (3, nil) },
            enumerationProvider: { _ in
                .init(
                    returnedCount: 3,
                    processIDs: [9_999, 10_000, 10_001],
                    errorCode: nil
                )
            },
            memberStateProvider: { _ in .exitedOrZombie }
        )
        XCTAssertEqual(allZombie, .absent)

        let unreadableTail = DescriptorBoundProcessGroupMemberPolicy.presence(
            rootProcessIdentifier: 9_999,
            countProvider: { (3, nil) },
            enumerationProvider: { _ in
                .init(
                    returnedCount: 3,
                    processIDs: [9_999, 10_000, 10_001],
                    errorCode: nil
                )
            },
            memberStateProvider: { processIdentifier in
                processIdentifier == 10_001
                    ? .indeterminate(EPERM)
                    : .exitedOrZombie
            }
        )
        XCTAssertEqual(unreadableTail, .indeterminate(EPERM))
    }

    func testDescriptorProcessGroupReenumeratesAfterZombieProofAndFindsForkedChild() {
        let rootProcessIdentifier: pid_t = 9_999
        let exitedParent: pid_t = 10_000
        let forkedChild: pid_t = 10_001
        var enumerationCallCount = 0

        let presence = DescriptorBoundProcessGroupMemberPolicy.presence(
            rootProcessIdentifier: rootProcessIdentifier,
            countProvider: { (2, nil) },
            enumerationProvider: { _ in
                enumerationCallCount += 1
                switch enumerationCallCount {
                case 1:
                    return .init(
                        returnedCount: 2,
                        processIDs: [rootProcessIdentifier, exitedParent],
                        errorCode: nil
                    )
                case 2, 3:
                    // The count is unchanged, but the exact member set changed
                    // after the first parent forked and exited.
                    return .init(
                        returnedCount: 2,
                        processIDs: [rootProcessIdentifier, forkedChild],
                        errorCode: nil
                    )
                default:
                    XCTFail("unexpected extra process-group enumeration")
                    return .init(
                        returnedCount: 1,
                        processIDs: [rootProcessIdentifier],
                        errorCode: nil
                    )
                }
            },
            memberStateProvider: { processIdentifier in
                processIdentifier == forkedChild
                    ? .active
                    : .exitedOrZombie
            }
        )

        XCTAssertEqual(presence, .present)
        XCTAssertEqual(enumerationCallCount, 3)
    }

    func testDescriptorProcessGroupEnumerationFailsClosedAfterPersistentSaturation() {
        var capacities: [Int] = []

        let presence = DescriptorBoundProcessGroupMemberPolicy.presence(
            rootProcessIdentifier: 9_999,
            maximumEnumerationAttempts: 2,
            countProvider: { (22, nil) },
            enumerationProvider: { capacity in
                capacities.append(capacity)
                return .init(
                    returnedCount: capacity,
                    processIDs: Array(repeating: 10_000, count: capacity),
                    errorCode: nil
                )
            },
            memberStateProvider: { _ in .exitedOrZombie }
        )

        XCTAssertEqual(presence, .indeterminate(EOVERFLOW))
        XCTAssertEqual(capacities.count, 2)
        XCTAssertGreaterThan(capacities[1], capacities[0])
    }

    func testDescriptorProcessGroupZeroRowsWithoutErrnoProveAbsence() {
        var enumerationCallCount = 0

        let zeroWithoutErrno = DescriptorBoundProcessGroupMemberPolicy
            .presence(
                rootProcessIdentifier: 9_999,
                countProvider: { (0, nil) },
                enumerationProvider: { _ in
                    enumerationCallCount += 1
                    return .init(
                        returnedCount: 0,
                        processIDs: [],
                        errorCode: nil
                    )
                },
                memberStateProvider: { _ in .exitedOrZombie }
            )
        XCTAssertEqual(zeroWithoutErrno, .absent)

        let zeroEnumerationAfterUpperBoundHint =
            DescriptorBoundProcessGroupMemberPolicy.presence(
                rootProcessIdentifier: 9_999,
                countProvider: { (128, nil) },
                enumerationProvider: { _ in
                    enumerationCallCount += 1
                    return .init(
                        returnedCount: 0,
                        processIDs: [],
                        errorCode: nil
                    )
                },
                memberStateProvider: { _ in .exitedOrZombie }
            )
        XCTAssertEqual(zeroEnumerationAfterUpperBoundHint, .absent)

        let zeroWithErrno = DescriptorBoundProcessGroupMemberPolicy.presence(
            rootProcessIdentifier: 9_999,
            countProvider: { (0, EPERM) },
            enumerationProvider: { _ in
                enumerationCallCount += 1
                return .init(
                    returnedCount: 0,
                    processIDs: [],
                    errorCode: nil
                )
            },
            memberStateProvider: { _ in .exitedOrZombie }
        )
        XCTAssertEqual(zeroWithErrno, .indeterminate(EPERM))
        XCTAssertEqual(
            enumerationCallCount,
            1,
            "a successful zero-row enumeration is absence; an errno-bearing count remains fail-closed"
        )
    }

    func testManagedWineLoaderReadbackFailureRetriesOnlyAfterExitOrPIDReuse() {
        let expectedStart: UInt64 = 1_800_000_000_123_456

        XCTAssertEqual(
            SafeProcessRunner
                .managedWineReadbackFailureIdentityDisposition(
                    expectedStartTimeUnixMicroseconds: expectedStart,
                    identityAfterReadback: .exited
                ),
            .candidateExited
        )
        XCTAssertEqual(
            SafeProcessRunner
                .managedWineReadbackFailureIdentityDisposition(
                    expectedStartTimeUnixMicroseconds: expectedStart,
                    identityAfterReadback: .live(
                        startedAtUnixMicroseconds: expectedStart + 1
                    )
                ),
            .candidateWasReused(
                observedStartTimeUnixMicroseconds: expectedStart + 1
            )
        )
        XCTAssertEqual(
            SafeProcessRunner
                .managedWineReadbackFailureIdentityDisposition(
                    expectedStartTimeUnixMicroseconds: expectedStart,
                    identityAfterReadback: .live(
                        startedAtUnixMicroseconds: expectedStart
                    )
                ),
            .failClosed,
            "a readback failure from the same exact live loader must propagate immediately"
        )
        XCTAssertEqual(
            SafeProcessRunner
                .managedWineReadbackFailureIdentityDisposition(
                    expectedStartTimeUnixMicroseconds: expectedStart,
                    identityAfterReadback: .unavailable
                ),
            .failClosed,
            "an unreadable-present loader must remain fail-closed"
        )
    }

    func testTerminalDescriptorRootUsesSameSessionReadbackBeforeOrAfterReap() {
        XCTAssertTrue(
            SafeProcessRunner.descriptorRootRequiresSameSessionReadback(
                rootWaitObservation: .terminalStateObserved,
                rootWasActuallyReaped: false
            )
        )
        XCTAssertTrue(
            SafeProcessRunner.descriptorRootRequiresSameSessionReadback(
                rootWaitObservation: .terminalStateObserved,
                rootWasActuallyReaped: true
            ),
            "reaping a proven exited helper must not send readback back to its dead PID"
        )
        XCTAssertFalse(
            SafeProcessRunner.descriptorRootRequiresSameSessionReadback(
                rootWaitObservation: .awaitingTerminalState,
                rootWasActuallyReaped: false
            )
        )
        XCTAssertFalse(
            SafeProcessRunner.descriptorRootRequiresSameSessionReadback(
                rootWaitObservation: .failed(ECHILD),
                rootWasActuallyReaped: false
            ),
            "a wait observation failure remains fail-closed"
        )
    }

    func testReapedDescriptorRootNeverRequeriesReusedProcessGroup() {
        var countProbeCount = 0
        var enumerationCount = 0
        var memberProbeCount = 0

        let presence = DescriptorBoundProcessGroupMemberPolicy.presence(
            rootProcessIdentifier: 42_019,
            rootPIDReuseBarrierRetired: true,
            countProvider: {
                countProbeCount += 1
                return (1, nil)
            },
            enumerationProvider: { _ in
                enumerationCount += 1
                return .init(
                    returnedCount: 1,
                    processIDs: [42_020],
                    errorCode: nil
                )
            },
            memberStateProvider: { _ in
                memberProbeCount += 1
                return .active
            }
        )

        XCTAssertEqual(presence, .absent)
        XCTAssertEqual(countProbeCount, 0)
        XCTAssertEqual(enumerationCount, 0)
        XCTAssertEqual(memberProbeCount, 0)
    }

    func testReapFailureDoesNotRetainDescriptorPIDIdentityBarrier() {
        XCTAssertTrue(
            SafeProcessRunner.descriptorRootRetainsUnreapedIdentityBarrier(
                rootWaitObservation: .terminalStateObserved,
                rootWasActuallyReaped: false,
                rootReapError: nil,
                reapInProgress: false
            )
        )
        XCTAssertFalse(
            SafeProcessRunner.descriptorRootRetainsUnreapedIdentityBarrier(
                rootWaitObservation: .terminalStateObserved,
                rootWasActuallyReaped: false,
                rootReapError: ECHILD,
                reapInProgress: false
            ),
            "a failed reap cannot authorize journal skipping or numeric PGID signaling"
        )
        XCTAssertFalse(
            SafeProcessRunner.descriptorRootRetainsUnreapedIdentityBarrier(
                rootWaitObservation: .terminalStateObserved,
                rootWasActuallyReaped: false,
                rootReapError: nil,
                reapInProgress: true
            )
        )
    }

    func testSameSessionLiveLoaderReadbackFailureIsImmediateAndSingleAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayReadbackFailClosed-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let runtimeRoot = root.appending(
            path: "ForgePlayRuntime/wine",
            directoryHint: .isDirectory
        )
        let loader = runtimeRoot.appending(path: "bin/wine.bin")
        let evidenceURL = root.appending(path: "managed-wine.jsonl")
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: loader.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/sleep"),
            to: loader
        )
        let registeredAt = Date()
        let process = Process()
        process.executableURL = loader
        process.arguments = ["60"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }
        let processStartedAt = try XCTUnwrap(
            ManagedWineProcessJournal.processStartTimeUnixMicroseconds(
                for: process.processIdentifier
            )
        )
        let runIdentifier = UUID().uuidString.lowercased()
        let runtimeFingerprint = String(repeating: "a", count: 64)
        let prefixScope = ManagedWineProcessJournal.prefixScope(for: prefix)
        let recordedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        let row =
            "{\"schema_version\":1," +
            "\"producer\":\"forgeplay-wine-runtime\"," +
            "\"event_code\":\"darwin_process_started\"," +
            "\"role\":\"wine-loader\"," +
            "\"run_identifier\":\"\(runIdentifier)\"," +
            "\"prefix_scope\":\"\(prefixScope)\"," +
            "\"runtime_fingerprint\":\"\(runtimeFingerprint)\"," +
            "\"darwin_pid\":\(process.processIdentifier)," +
            "\"recorded_at_unix_milliseconds\":\(recordedAt)," +
            "\"process_started_at_unix_microseconds\":\(processStartedAt)}\n"
        try Data(row.utf8).write(to: evidenceURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: evidenceURL.path
        )
        let launchSession = ManagedWineProcessLaunchSession(
            prefixURL: prefix,
            runIdentifier: runIdentifier,
            evidenceURL: evidenceURL,
            runtimeRootURL: runtimeRoot,
            runtimeFingerprint: runtimeFingerprint,
            prefixScope: prefixScope,
            registeredAt: registeredAt
        )
        let state = ManagedWineReadbackTestState()
        let expectedError = NSError(
            domain: "SafeProcessRunnerTests.LiveReadbackFailure",
            code: 94
        )
        let runner = makeCuratedRuntimeRunner(
            sandboxEnabled: true,
            managedWineChildSynchronizationReadbackProvider: {
                processIdentifier in
                state.recordReadback(processIdentifier: processIdentifier)
                throw expectedError
            }
        )
        let startedAt = Date()
        do {
            _ = try await runner.sameSessionManagedWineLoaderReadback(
                for: launchSession,
                primaryProcessIdentifier: 99_999,
                timeout: 5,
                pollInterval: 0.05
            )
            XCTFail("a still-live exact loader readback failure must propagate")
        } catch {
            let observed = error as NSError
            XCTAssertEqual(observed.domain, expectedError.domain)
            XCTAssertEqual(observed.code, expectedError.code)
        }
        XCTAssertEqual(
            state.readbackProcessIdentifiers,
            [process.processIdentifier]
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            1,
            "terminal readback failure must not poll until the five-second deadline"
        )
        process.terminate()
        process.waitUntilExit()
    }

    func testManagedWineIdentityResolutionUsesIdentityThatBecomesReadable() {
        let expectedStart: UInt64 = 1_800_000_000_123_456
        var startProbeCount = 0
        var waitCount = 0

        let resolution = ManagedWineProcessJournal
            .resolveProcessIdentityAcrossExitBoundary(
                for: 42_002,
                retryCount: 2,
                retryInterval: 0.025,
                startTimeProvider: { _ in
                    startProbeCount += 1
                    return startProbeCount == 1 ? nil : expectedStart
                },
                livenessProvider: { _ in .present },
                wait: { _ in waitCount += 1 }
            )

        XCTAssertEqual(
            resolution,
            .live(startedAtUnixMicroseconds: expectedStart)
        )
        XCTAssertEqual(startProbeCount, 2)
        XCTAssertEqual(waitCount, 1)
    }

    func testManagedWineSignalIdentityRejectsOneMicrosecondPIDReuse() {
        let expectedStart: UInt64 = 1_800_000_000_123_456

        XCTAssertTrue(
            ManagedWineProcessJournal.isExactLiveProcessIdentity(
                .live(startedAtUnixMicroseconds: expectedStart),
                expectedStartTimeUnixMicroseconds: expectedStart
            )
        )
        XCTAssertFalse(
            ManagedWineProcessJournal.isExactLiveProcessIdentity(
                .live(startedAtUnixMicroseconds: expectedStart + 1),
                expectedStartTimeUnixMicroseconds: expectedStart
            ),
            "a one-microsecond start-identity difference proves PID reuse"
        )
        XCTAssertFalse(
            ManagedWineProcessJournal.isExactLiveProcessIdentity(
                .exited,
                expectedStartTimeUnixMicroseconds: expectedStart
            )
        )
        XCTAssertFalse(
            ManagedWineProcessJournal.isExactLiveProcessIdentity(
                .unavailable,
                expectedStartTimeUnixMicroseconds: expectedStart
            )
        )
    }

    func testLsofCollectionCannotBypassOneMicrosecondJournalTargetReuse() {
        let collectedStart: UInt64 = 1_800_000_000_123_456
        let executable = URL(fileURLWithPath: "/tmp/ForgePlayRuntime/wine")
        let target = ManagedProcessSignalTarget(
            processID: 42_003,
            processStartedAtUnixMicroseconds: collectedStart,
            executableURL: executable,
            source: .managedWineJournal
        )

        XCTAssertTrue(
            SafeProcessRunner.managedSignalTargetPassesFinalValidation(
                target,
                firstObservedStartTimeUnixMicroseconds: collectedStart,
                observedExecutableURL: executable,
                finalObservedStartTimeUnixMicroseconds: collectedStart
            )
        )
        XCTAssertFalse(
            SafeProcessRunner.managedSignalTargetPassesFinalValidation(
                target,
                firstObservedStartTimeUnixMicroseconds: collectedStart,
                observedExecutableURL: executable,
                finalObservedStartTimeUnixMicroseconds: collectedStart + 1
            ),
            "collection must not authorize a replacement process that reused the PID one microsecond later"
        )
        XCTAssertFalse(
            SafeProcessRunner.managedSignalTargetPassesFinalValidation(
                target,
                firstObservedStartTimeUnixMicroseconds: collectedStart,
                observedExecutableURL: nil,
                finalObservedStartTimeUnixMicroseconds: collectedStart
            )
        )
    }

    func testFoundationAndGameModeTargetsRejectPIDReuseWithSameExecutablePath() {
        let start: UInt64 = 1_800_000_000_123_456
        let executable = URL(fileURLWithPath: "/tmp/ForgePlayRuntime/wine")
        for source in [
            ManagedProcessSignalOwnershipSource.trackedFoundationProcess,
            .gameModeHostJournal
        ] {
            let target = ManagedProcessSignalTarget(
                processID: 42_004,
                processStartedAtUnixMicroseconds: start,
                executableURL: executable,
                source: source
            )
            XCTAssertFalse(
                SafeProcessRunner.managedSignalTargetPassesFinalValidation(
                    target,
                    firstObservedStartTimeUnixMicroseconds: start + 1,
                    observedExecutableURL: executable,
                    finalObservedStartTimeUnixMicroseconds: start + 1
                ),
                "same-path PID reuse must not authorize \(source.rawValue)"
            )
        }
    }

    func testDescriptorBoundTrackerAllowsExecTransitionOnlyForTheSameProcessStart() {
        let start: UInt64 = 1_800_000_000_123_456
        let launchExecutable = URL(fileURLWithPath: "/bin/sh")
        let currentExecutable = URL(fileURLWithPath: "/bin/zsh")
        let descriptorTarget = ManagedProcessSignalTarget(
            processID: 42_005,
            processStartedAtUnixMicroseconds: start,
            executableURL: launchExecutable,
            source: .trackedDescriptorBoundProcess
        )

        XCTAssertTrue(
            SafeProcessRunner.managedSignalTargetPassesFinalValidation(
                descriptorTarget,
                firstObservedStartTimeUnixMicroseconds: start,
                observedExecutableURL: currentExecutable,
                finalObservedStartTimeUnixMicroseconds: start
            ),
            "the retained WNOWAIT leader remains owned across exec"
        )
        XCTAssertFalse(
            SafeProcessRunner.managedSignalTargetPassesFinalValidation(
                descriptorTarget,
                firstObservedStartTimeUnixMicroseconds: start + 1,
                observedExecutableURL: currentExecutable,
                finalObservedStartTimeUnixMicroseconds: start + 1
            ),
            "a one-microsecond start change proves PID reuse"
        )
        XCTAssertFalse(
            SafeProcessRunner.managedSignalTargetPassesFinalValidation(
                descriptorTarget,
                firstObservedStartTimeUnixMicroseconds: start,
                observedExecutableURL: nil,
                finalObservedStartTimeUnixMicroseconds: start
            ),
            "an unreadable current executable must fail closed"
        )

        for source in [
            ManagedProcessSignalOwnershipSource.managedWineJournal,
            .gameModeHostJournal,
            .trackedFoundationProcess
        ] {
            let target = ManagedProcessSignalTarget(
                processID: 42_005,
                processStartedAtUnixMicroseconds: start,
                executableURL: launchExecutable,
                source: source
            )
            XCTAssertFalse(
                SafeProcessRunner.managedSignalTargetPassesFinalValidation(
                    target,
                    firstObservedStartTimeUnixMicroseconds: start,
                    observedExecutableURL: currentExecutable,
                    finalObservedStartTimeUnixMicroseconds: start
                ),
                "an executable transition must not authorize \(source.rawValue)"
            )
        }
    }

    func testMissingDescriptorOrFoundationTrackerCannotAuthorizeRawSignalFallback() {
        XCTAssertTrue(
            SafeProcessRunner.managedSignalSourceRequiresRetainedTracker(
                .trackedDescriptorBoundProcess
            )
        )
        XCTAssertTrue(
            SafeProcessRunner.managedSignalSourceRequiresRetainedTracker(
                .trackedFoundationProcess
            )
        )
        XCTAssertFalse(
            SafeProcessRunner.managedSignalSourceRequiresRetainedTracker(
                .managedWineJournal
            )
        )
        XCTAssertFalse(
            SafeProcessRunner.managedSignalSourceRequiresRetainedTracker(
                .gameModeHostJournal
            )
        )
    }

    func testLatestLsofSnapshotCarriesNewHolderIntoInspection() {
        XCTAssertEqual(
            SafeProcessRunner
                .latestPrefixHolderProcessIDsRequiringInspection(
                    initialSnapshot: [42_010],
                    latestSnapshot: [42_010, 42_011]
                ),
            [42_010, 42_011]
        )
        XCTAssertEqual(
            SafeProcessRunner
                .latestPrefixHolderProcessIDsRequiringInspection(
                    initialSnapshot: [42_010],
                    latestSnapshot: [42_011]
                ),
            [42_011],
            "the newest lsof snapshot, including newly appeared holders, is authoritative"
        )
    }

    func testExitedDescriptorLeaderRequiresExactRetainedCapabilityAndLiveGroup() {
        let descriptorCapability = ManagedProcessSignalTarget(
            processID: 42_012,
            processStartedAtUnixMicroseconds: 1_800_000_000_123_456,
            executableURL: URL(fileURLWithPath: "/tmp/descriptor-child"),
            source: .trackedDescriptorBoundProcess
        )
        let journalCapability = ManagedProcessSignalTarget(
            processID: 42_012,
            processStartedAtUnixMicroseconds: 1_800_000_000_123_456,
            executableURL: URL(fileURLWithPath: "/tmp/descriptor-child"),
            source: .managedWineJournal
        )
        let conflictingDescriptorCapability = ManagedProcessSignalTarget(
            processID: 42_012,
            processStartedAtUnixMicroseconds: 1_800_000_000_123_457,
            executableURL: URL(fileURLWithPath: "/tmp/descriptor-child"),
            source: .trackedDescriptorBoundProcess
        )

        XCTAssertFalse(
            SafeProcessRunner
                .descriptorBoundSignalCapabilityAuthorizesOwnership(
                    processID: 42_012,
                    signalCapability: nil
                ),
            "an exited leader's retained group is not raw signal authority"
        )
        XCTAssertFalse(
            SafeProcessRunner
                .descriptorBoundSignalCapabilityAuthorizesOwnership(
                    processID: 42_012,
                    signalCapability: journalCapability
                )
        )
        XCTAssertTrue(
            SafeProcessRunner
                .descriptorBoundSignalCapabilityAuthorizesOwnership(
                    processID: 42_012,
                    signalCapability: descriptorCapability
                )
        )
        XCTAssertTrue(
            SafeProcessRunner
                .exitedDescriptorBoundGroupSignalIsAuthorized(
                    processID: 42_012,
                    signalCapability: descriptorCapability,
                    retainedSignalCapability: descriptorCapability,
                    leaderExitObserved: true,
                    hasTrackedOwnership: true
                ),
            "an unreaped exact leader anchors its live descendant group"
        )
        XCTAssertFalse(
            SafeProcessRunner
                .exitedDescriptorBoundGroupSignalIsAuthorized(
                    processID: 42_012,
                    signalCapability: descriptorCapability,
                    retainedSignalCapability: nil,
                    leaderExitObserved: true,
                    hasTrackedOwnership: true
                ),
            "a live group without its retained launch capability must fail closed"
        )
        XCTAssertFalse(
            SafeProcessRunner
                .exitedDescriptorBoundGroupSignalIsAuthorized(
                    processID: 42_012,
                    signalCapability: descriptorCapability,
                    retainedSignalCapability:
                        conflictingDescriptorCapability,
                    leaderExitObserved: true,
                    hasTrackedOwnership: true
                ),
            "a conflicting retained capability must fail closed"
        )
        XCTAssertFalse(
            SafeProcessRunner
                .exitedDescriptorBoundGroupSignalIsAuthorized(
                    processID: 42_012,
                    signalCapability: descriptorCapability,
                    retainedSignalCapability: descriptorCapability,
                    leaderExitObserved: false,
                    hasTrackedOwnership: true
                ),
            "a live leader must use start/executable/start validation"
        )
        XCTAssertFalse(
            SafeProcessRunner
                .exitedDescriptorBoundGroupSignalIsAuthorized(
                    processID: 42_012,
                    signalCapability: descriptorCapability,
                    retainedSignalCapability: descriptorCapability,
                    leaderExitObserved: true,
                    hasTrackedOwnership: false
                ),
            "an absent retained group is not signal authority"
        )
    }

    func testPIDReuseExclusionSurvivesLiveAndUnreadableObservationsUntilExit() {
        XCTAssertFalse(
            SafeProcessRunner.managedSignalExclusionMayBeRetired(
                after: .live(startedAtUnixMicroseconds: 101)
            )
        )
        XCTAssertFalse(
            SafeProcessRunner.managedSignalExclusionMayBeRetired(
                after: .unavailable
            )
        )
        XCTAssertTrue(
            SafeProcessRunner.managedSignalExclusionMayBeRetired(
                after: .exited
            )
        )
    }

    func testConflictingSignalIdentityObstructsAndWeakSourceCannotOverwriteStrongSource() {
        let executable = URL(fileURLWithPath: "/tmp/ForgePlayRuntime/wine")
        let strong = ManagedProcessSignalTarget(
            processID: 42_005,
            processStartedAtUnixMicroseconds: 100,
            executableURL: executable,
            source: .trackedFoundationProcess
        )
        let conflicting = ManagedProcessSignalTarget(
            processID: 42_005,
            processStartedAtUnixMicroseconds: 101,
            executableURL: executable,
            source: .managedWineJournal
        )
        let matchingWeak = ManagedProcessSignalTarget(
            processID: 42_005,
            processStartedAtUnixMicroseconds: 100,
            executableURL: executable,
            source: .gameModeHostJournal
        )

        XCTAssertEqual(
            SafeProcessRunner.managedSignalCapabilityMergeDecision(
                existing: strong,
                candidate: conflicting
            ),
            .obstruct
        )
        XCTAssertEqual(
            SafeProcessRunner.managedSignalCapabilityMergeDecision(
                existing: strong,
                candidate: matchingWeak
            ),
            .keepExisting
        )
    }

    func testManagedWineActiveSessionDescriptorIsAtomicPrivateAndPathFree() throws {
        let fixture = try makeManagedWineDescriptorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var status = stat()
        XCTAssertEqual(lstat(fixture.descriptorURL.path, &status), 0)
        XCTAssertEqual(status.st_uid, geteuid())
        XCTAssertEqual(status.st_nlink, 1)
        XCTAssertEqual(
            status.st_mode & mode_t(0o777),
            S_IRUSR | S_IWUSR
        )
        let raw = try String(
            contentsOf: fixture.descriptorURL,
            encoding: .utf8
        )
        XCTAssertFalse(raw.contains(fixture.prefix.path), raw)
        XCTAssertFalse(raw.contains(fixture.runtimeRoot.path), raw)
        XCTAssertTrue(raw.contains(fixture.runIdentifier), raw)

        let registry = ManagedWineSessionRegistry()
        let hydrated = try registry.hydrate(
            from: fixture.evidenceDirectory,
            trustedAncestor: fixture.root,
            for: fixture.prefix,
            runtimeRootURL: fixture.runtimeRoot,
            runtimeFingerprint: fixture.runtimeFingerprint,
            validating: { _ in }
        )
        XCTAssertEqual(hydrated.count, 1)
        XCTAssertEqual(hydrated.first?.descriptorURL, fixture.descriptorURL)
        XCTAssertEqual(hydrated.first?.evidenceURL, fixture.evidenceURL)
        XCTAssertEqual(
            registry.launchSessions(for: fixture.prefix),
            hydrated
        )
    }

    func testManagedWineSessionHydrationRejectsExactLiveForeignOwner() throws {
        let foreignOwner = Darwin.getppid()
        guard foreignOwner > 1,
              let foreignOwnerStartedAt = ManagedWineProcessJournal
                .processStartTimeUnixMicroseconds(for: foreignOwner) else {
            throw XCTSkip("A live parent process identity is unavailable.")
        }
        let fixture = try makeManagedWineDescriptorFixture(
            ownerProcessIdentifier: foreignOwner,
            ownerProcessStartedAt: foreignOwnerStartedAt
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let registry = ManagedWineSessionRegistry()

        XCTAssertThrowsError(try registry.hydrate(
            from: fixture.evidenceDirectory,
            trustedAncestor: fixture.root,
            for: fixture.prefix,
            runtimeRootURL: fixture.runtimeRoot,
            runtimeFingerprint: fixture.runtimeFingerprint,
            validating: { _ in
                XCTFail("A live foreign owner must fail before PID validation.")
            }
        ))
        XCTAssertTrue(registry.launchSessions(for: fixture.prefix).isEmpty)
    }

    func testManagedWineSessionHydrationRejectsLiveLegacyJournalWithoutOwnerDescriptor() throws {
        let fixture = try makeManagedWineDescriptorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.descriptorURL)
        let processStartedAt = try XCTUnwrap(
            ManagedWineProcessJournal.processStartTimeUnixMicroseconds(
                for: Darwin.getpid()
            )
        )
        let record =
            "{\"schema_version\":1," +
            "\"producer\":\"forgeplay-wine-runtime\"," +
            "\"event_code\":\"darwin_process_started\"," +
            "\"role\":\"wineserver\"," +
            "\"run_identifier\":\"\(fixture.runIdentifier)\"," +
            "\"prefix_scope\":\"\(ManagedWineProcessJournal.prefixScope(for: fixture.prefix))\"," +
            "\"runtime_fingerprint\":\"\(fixture.runtimeFingerprint)\"," +
            "\"darwin_pid\":\(Darwin.getpid())," +
            "\"process_started_at_unix_microseconds\":\(processStartedAt)}\n"
        try Data(record.utf8).write(to: fixture.evidenceURL)
        let registry = ManagedWineSessionRegistry()

        XCTAssertThrowsError(try registry.hydrate(
            from: fixture.evidenceDirectory,
            trustedAncestor: fixture.root,
            for: fixture.prefix,
            runtimeRootURL: fixture.runtimeRoot,
            runtimeFingerprint: fixture.runtimeFingerprint,
            validating: { _ in
                XCTFail("A descriptor-less live journal must never publish a session.")
            }
        ))
        XCTAssertTrue(registry.launchSessions(for: fixture.prefix).isEmpty)
    }

    func testManagedWineSessionHydrationRejectsHardlinkedDescriptor() throws {
        let fixture = try makeManagedWineDescriptorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let hardlink = fixture.evidenceDirectory.appending(
            path: "descriptor-hardlink-fixture"
        )
        try FileManager.default.linkItem(
            at: fixture.descriptorURL,
            to: hardlink
        )
        let registry = ManagedWineSessionRegistry()

        XCTAssertThrowsError(try registry.hydrate(
            from: fixture.evidenceDirectory,
            trustedAncestor: fixture.root,
            for: fixture.prefix,
            runtimeRootURL: fixture.runtimeRoot,
            runtimeFingerprint: fixture.runtimeFingerprint,
            validating: { _ in
                XCTFail("A hardlinked descriptor must fail before PID validation.")
            }
        ))
        XCTAssertTrue(registry.launchSessions(for: fixture.prefix).isEmpty)
    }

    func testManagedWineSessionHydrationPublishesNoPartialPIDValidation() throws {
        let fixture = try makeManagedWineDescriptorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let registry = ManagedWineSessionRegistry()

        XCTAssertThrowsError(try registry.hydrate(
            from: fixture.evidenceDirectory,
            trustedAncestor: fixture.root,
            for: fixture.prefix,
            runtimeRootURL: fixture.runtimeRoot,
            runtimeFingerprint: fixture.runtimeFingerprint,
            validating: { launchSession in
                throw SafeProcessRunnerError.prefixProcessVerificationFailed(
                    launchSession.evidenceURL,
                    "fixture PID/executable identity is ambiguous"
                )
            }
        ))
        XCTAssertTrue(registry.launchSessions(for: fixture.prefix).isEmpty)
        XCTAssertTrue(registry.prefixURLs.isEmpty)
    }

    func testManagedWineRuntimePatchRecordsDaemonAndBoundsOwnerDeath() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let patchURL = repositoryRoot.appending(
            path: "Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-managed-darwin-process-journal.patch"
        )
        let patch = try String(contentsOf: patchURL, encoding: .utf8)
        let socketIndex = try XCTUnwrap(
            patch.range(of: "     open_master_socket();", options: .backwards)?
                .lowerBound
        )
        let recordIndex = try XCTUnwrap(
            patch.range(
                of: "+    forgeplay_record_managed_wine_process( \"wineserver\" );",
                options: .backwards
            )?.lowerBound
        )

        XCTAssertLessThan(socketIndex, recordIndex)
        XCTAssertTrue(patch.contains("kill( getpid(), SIGTERM )"), patch)
        XCTAssertTrue(patch.contains("struct timespec delay = {2, 0}"), patch)
        XCTAssertTrue(patch.contains("nanosleep( &delay, &remaining )"), patch)
        XCTAssertTrue(patch.contains("_exit(1);"), patch)
        XCTAssertTrue(
            patch.contains(
                "action=graceful-then-hard-watchdog"
            ),
            patch
        )
    }

    func testConfirmedPrefixCleanupClearsSessionOwnershipWhenEvidenceDeletionFails() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlaySessionEvidenceCleanup-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let evidenceDirectory = root.appending(
            path: "Evidence",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: evidenceDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: evidenceDirectory.path
            )
        }

        let runIdentifier = UUID().uuidString.lowercased()
        let prefixScope = ManagedWineProcessJournal.prefixScope(for: prefix)
        let runtimeFingerprint = String(repeating: "a", count: 64)
        let registeredAt = Date()
        let startedMicroseconds = Int64(
            registeredAt.timeIntervalSince1970 * 1_000_000
        )
        let recordedMilliseconds = Int64(
            registeredAt.timeIntervalSince1970 * 1_000
        )
        let evidenceURL = evidenceDirectory.appending(
            path: "\(runIdentifier).jsonl"
        )
        let deadProcessIdentifier = Int32.max
        try Data((
            "{\"schema_version\":1," +
            "\"producer\":\"forgeplay-wine-runtime\"," +
            "\"event_code\":\"darwin_process_started\"," +
            "\"role\":\"wine-loader\"," +
            "\"run_identifier\":\"\(runIdentifier)\"," +
            "\"prefix_scope\":\"\(prefixScope)\"," +
            "\"runtime_fingerprint\":\"\(runtimeFingerprint)\"," +
            "\"darwin_pid\":\(deadProcessIdentifier)," +
            "\"recorded_at_unix_milliseconds\":\(recordedMilliseconds)," +
            "\"process_started_at_unix_microseconds\":\(startedMicroseconds)}\n"
        ).utf8).write(to: evidenceURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: evidenceURL.path
        )

        let registry = ManagedWineSessionRegistry()
        registry.record(
            ManagedWineProcessLaunchSession(
                prefixURL: prefix,
                runIdentifier: runIdentifier,
                evidenceURL: evidenceURL,
                runtimeRootURL: root.appending(
                    path: "FakeRuntime/wine",
                    directoryHint: .isDirectory
                ),
                runtimeFingerprint: runtimeFingerprint,
                prefixScope: prefixScope,
                registeredAt: registeredAt
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: evidenceDirectory.path
        )
        let launcher = try makeWineRunner(
            in: root,
            wineserverScript: "#!/bin/sh\nexit 0\n"
        )
        let runner = makeCuratedRuntimeRunner(
            sandboxEnabled: true,
            managedWineSessionRegistry: registry
        )

        let result = try await runner.run(
            .shutdownWinePrefix(
                runtimeExecutable: launcher,
                prefix: prefix,
                logDirectory: logs
            )
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.postconditionSatisfied, true)
        XCTAssertTrue(registry.launchSessions(for: prefix).isEmpty)
        XCTAssertFalse(registry.prefixURLs.contains(prefix.standardizedFileURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidenceURL.path))
        XCTAssertTrue(
            result.diagnosticCaptureWarning?
                .contains("ownership artifact(s) could not be removed") == true
        )
    }

    func testAnchoredACFSnapshotStaysImmutableAndLeaseRejectsSameInodeMutation() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayAnchoredACF-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let manifest = root.appending(path: "appmanifest_553850.acf")
        try Data("abcdefgh".utf8).write(to: manifest)
        let descriptor = Darwin.open(
            manifest.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        var status = stat()
        XCTAssertEqual(fstat(descriptor, &status), 0)
        let entry = CompatibilityAnchoredPathIdentityV1.Entry(
            path: manifest.path,
            kind: .regularFile,
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
        let lease = try CompatibilityAnchoredPathCapabilityLeaseV1(
            entries: [entry],
            descriptors: [descriptor]
        )
        let identity = CompatibilityAnchoredPathIdentityV1(
            entries: [entry],
            capabilityLease: lease
        )
        let snapshot = try OwnerPrivateUnlinkedFileSnapshotV1(
            copyingSourceDescriptor: descriptor,
            maximumByteCount: 512 * 1024 * 1024
        )
        var snapshotStatus = stat()
        XCTAssertEqual(fstat(snapshot.descriptor, &snapshotStatus), 0)
        XCTAssertEqual(snapshotStatus.st_nlink, 0)
        XCTAssertEqual(
            Darwin.fcntl(snapshot.descriptor, F_GETFL, 0) & O_ACCMODE,
            O_RDONLY
        )
        XCTAssertNoThrow(try identity.revalidate())

        let writer = Darwin.open(manifest.path, O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(writer, 0)
        guard writer >= 0 else { return }
        let replacement = Array("ijklmnop".utf8)
        let written = replacement.withUnsafeBytes { bytes in
            Darwin.pwrite(
                writer,
                bytes.baseAddress,
                bytes.count,
                0
            )
        }
        XCTAssertEqual(written, replacement.count)
        XCTAssertEqual(Darwin.fsync(writer), 0)
        Darwin.close(writer)

        var snapshotBytes = [UInt8](repeating: 0, count: 8)
        let snapshotByteCount = snapshotBytes.withUnsafeMutableBytes { bytes in
            Darwin.pread(
                snapshot.descriptor,
                bytes.baseAddress,
                bytes.count,
                0
            )
        }
        XCTAssertEqual(snapshotByteCount, snapshotBytes.count)
        XCTAssertEqual(String(decoding: snapshotBytes, as: UTF8.self), "abcdefgh")

        XCTAssertThrowsError(try identity.revalidate()) { error in
            guard case SteamCompatibilityLaunchProfileErrorV1.invalidReceipt(
                let reason
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(
                reason,
                "anchored-library-capability-content-changed"
            )
        }
    }

    func testAnchoredACFSpawnProjectionUsesSnapshotDirectoryLeaseAndCLOEXECDefault() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayAnchoredACFSpawn-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appending(path: "Library", directoryHint: .isDirectory)
        let manifest = library.appending(path: "appmanifest_553850.acf")
        let unlisted = root.appending(path: "unlisted.txt")
        let script = root.appending(path: "inspect-projection.py")
        let output = root.appending(path: "projection.txt")
        try FileManager.default.createDirectory(
            at: library,
            withIntermediateDirectories: true
        )
        let originalManifest = "original-acf-v1"
        try Data(originalManifest.utf8).write(to: manifest)
        try Data("must-not-be-inherited".utf8).write(to: unlisted)
        try #"""
        import base64
        import errno
        import os
        import stat
        import sys

        output = sys.argv[1]
        unlisted_fd = int(sys.argv[2])
        projection = os.environ["FORGEPLAY_BOUND_LIBRARY_OBJECT_FDS_V1"]

        with open(output, "w", encoding="utf-8") as stream:
            for row in projection.split("|"):
                fd_text, kind, encoded_path = row.split(":", 2)
                fd = int(fd_text)
                decoded_path = base64.b64decode(encoded_path).decode("utf-8")
                stream.write(f"row={fd}:{kind}:{decoded_path}\n")
                if kind == "directory":
                    descriptor_status = os.fstat(fd)
                    if not stat.S_ISDIR(descriptor_status.st_mode):
                        stream.write("directory-live=0\n")
                        sys.exit(92)
                    try:
                        marker = os.open(
                            "directory-live-marker",
                            os.O_RDONLY,
                            dir_fd=fd,
                        )
                    except OSError:
                        stream.write("directory-live=0\n")
                        sys.exit(92)
                    os.close(marker)
                    stream.write("directory-live=1\n")
                elif kind == "regularFile":
                    os.lseek(fd, 0, os.SEEK_SET)
                    payload = bytearray()
                    while True:
                        chunk = os.read(fd, 64 * 1024)
                        if not chunk:
                            break
                        payload.extend(chunk)
                    stream.write(
                        "snapshot-bytes=" + payload.decode("utf-8") + "\n"
                    )
                else:
                    sys.exit(93)

            try:
                os.fstat(unlisted_fd)
            except OSError as error:
                if error.errno != errno.EBADF:
                    raise
            else:
                stream.write("unlisted-closed=0\n")
                sys.exit(94)
            stream.write("unlisted-closed=1\n")
        """#.write(to: script, atomically: true, encoding: .utf8)

        let directoryDescriptor = Darwin.open(
            library.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        let manifestDescriptor = Darwin.open(
            manifest.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        // Intentionally omit O_CLOEXEC. POSIX_SPAWN_CLOEXEC_DEFAULT, rather
        // than the source descriptor flag, must keep this FD out of the child.
        let unlistedSourceDescriptor = Darwin.open(
            unlisted.path,
            O_RDONLY | O_NOFOLLOW
        )
        let unlistedDescriptor = unlistedSourceDescriptor >= 0
            ? Darwin.fcntl(unlistedSourceDescriptor, F_DUPFD, 150)
            : -1
        if unlistedSourceDescriptor >= 0 {
            Darwin.close(unlistedSourceDescriptor)
        }
        XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
        XCTAssertGreaterThanOrEqual(manifestDescriptor, 0)
        XCTAssertGreaterThanOrEqual(unlistedDescriptor, 0)
        guard directoryDescriptor >= 0,
              manifestDescriptor >= 0,
              unlistedDescriptor >= 0 else {
            if directoryDescriptor >= 0 { Darwin.close(directoryDescriptor) }
            if manifestDescriptor >= 0 { Darwin.close(manifestDescriptor) }
            if unlistedDescriptor >= 0 { Darwin.close(unlistedDescriptor) }
            return
        }
        defer {
            Darwin.close(directoryDescriptor)
            Darwin.close(manifestDescriptor)
            Darwin.close(unlistedDescriptor)
        }
        XCTAssertEqual(
            Darwin.fcntl(unlistedDescriptor, F_GETFD, 0) & FD_CLOEXEC,
            0
        )

        func entry(
            for url: URL,
            descriptor: Int32,
            kind: CompatibilityAnchoredPathIdentityV1.Kind
        ) throws -> CompatibilityAnchoredPathIdentityV1.Entry {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw CocoaError(.fileReadUnknown)
            }
            return CompatibilityAnchoredPathIdentityV1.Entry(
                path: url.path,
                kind: kind,
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino)
            )
        }

        let directoryEntry = try entry(
            for: library,
            descriptor: directoryDescriptor,
            kind: .directory
        )
        let manifestEntry = try entry(
            for: manifest,
            descriptor: manifestDescriptor,
            kind: .regularFile
        )
        let lease = try CompatibilityAnchoredPathCapabilityLeaseV1(
            entries: [directoryEntry, manifestEntry],
            descriptors: [directoryDescriptor, manifestDescriptor]
        )

        var fileActions: posix_spawn_file_actions_t?
        let fileActionsResult = posix_spawn_file_actions_init(&fileActions)
        XCTAssertEqual(fileActionsResult, 0)
        guard fileActionsResult == 0 else { return }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        var attributes: posix_spawnattr_t?
        let attributesResult = posix_spawnattr_init(&attributes)
        XCTAssertEqual(attributesResult, 0)
        guard attributesResult == 0 else { return }
        defer { posix_spawnattr_destroy(&attributes) }
        XCTAssertEqual(
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
            ),
            0
        )

        var environment = ["PATH": "/usr/bin:/bin"]
        let nextDescriptor = try lease.installSpawnCapabilities(
            fileActions: &fileActions,
            environment: &environment,
            startingAt: 200
        )
        let directoryTarget = nextDescriptor - 2
        let manifestTarget = nextDescriptor - 1
        XCTAssertGreaterThanOrEqual(directoryTarget, 200)
        let expectedProjection = [
            "\(directoryTarget):directory:" +
                Data(library.path.utf8).base64EncodedString(),
            "\(manifestTarget):regularFile:" +
                Data(manifest.path.utf8).base64EncodedString()
        ].joined(separator: "|")
        XCTAssertEqual(
            environment["FORGEPLAY_BOUND_LIBRARY_OBJECT_FDS_V1"],
            expectedProjection
        )
        try Data("created-after-capability-install".utf8).write(
            to: library.appending(path: "directory-live-marker")
        )

        let writer = Darwin.open(
            manifest.path,
            O_WRONLY | O_CLOEXEC | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(writer, 0)
        guard writer >= 0 else { return }
        let replacement = Array("mutated-acf-v1!".utf8)
        let written = replacement.withUnsafeBytes { bytes in
            Darwin.pwrite(writer, bytes.baseAddress, bytes.count, 0)
        }
        XCTAssertEqual(written, replacement.count)
        XCTAssertEqual(Darwin.fsync(writer), 0)
        XCTAssertEqual(Darwin.close(writer), 0)
        XCTAssertThrowsError(try lease.revalidate())

        func withCStringArray<Result>(
            _ values: [String],
            _ body: (
                UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
            ) -> Result
        ) -> Result {
            let strings = values.map { strdup($0)! }
            defer { strings.forEach { free($0) } }
            var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { $0 }
            pointers.append(nil)
            return pointers.withUnsafeMutableBufferPointer { buffer in
                body(buffer.baseAddress!)
            }
        }

        let arguments = [
            "/usr/bin/python3",
            script.path,
            output.path,
            String(unlistedDescriptor)
        ]
        let environmentRows = environment.keys.sorted().map {
            "\($0)=\(environment[$0] ?? "")"
        }
        var processIdentifier: pid_t = 0
        let spawnResult = withCStringArray(arguments) { argumentPointers in
            withCStringArray(environmentRows) { environmentPointers in
                posix_spawn(
                    &processIdentifier,
                    "/usr/bin/python3",
                    &fileActions,
                    &attributes,
                    argumentPointers,
                    environmentPointers
                )
            }
        }
        XCTAssertEqual(spawnResult, 0)
        XCTAssertGreaterThan(processIdentifier, 0)
        guard spawnResult == 0, processIdentifier > 0 else { return }
        var waitStatus: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = waitpid(processIdentifier, &waitStatus, 0)
        } while waitResult < 0 && errno == EINTR
        XCTAssertEqual(waitResult, processIdentifier)
        XCTAssertEqual(waitStatus, 0)

        let lines = try String(contentsOf: output, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(lines, [
            "row=\(directoryTarget):directory:\(library.path)",
            "directory-live=1",
            "row=\(manifestTarget):regularFile:\(manifest.path)",
            "snapshot-bytes=\(originalManifest)",
            "unlisted-closed=1"
        ])
    }

    func testManagedWineProcessJournalSelectsOnlyExactLaunchIdentity() {
        let registeredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let runIdentifier = "3d79c3a0-8d67-4b35-ba7e-644660a1f150"
        let prefixScope = String(repeating: "a", count: 64)
        let runtimeFingerprint = String(repeating: "b", count: 64)
        let launchSession = ManagedWineProcessLaunchSession(
            prefixURL: URL(fileURLWithPath: "/tmp/ForgePlay/Prefixes/Steam"),
            runIdentifier: runIdentifier,
            evidenceURL: URL(fileURLWithPath: "/tmp/managed-wine.jsonl"),
            runtimeRootURL: URL(fileURLWithPath: "/tmp/ForgePlayRuntime/wine"),
            runtimeFingerprint: runtimeFingerprint,
            prefixScope: prefixScope,
            registeredAt: registeredAt
        )
        let data = Data((
            """
            {"schema_version":1,"producer":"forgeplay-wine-runtime","event_code":"darwin_process_started","role":"wine-loader","run_identifier":"\(runIdentifier)","prefix_scope":"\(prefixScope)","runtime_fingerprint":"\(runtimeFingerprint)","darwin_pid":42001,"recorded_at_unix_milliseconds":1800000001000,"process_started_at_unix_microseconds":1800000000500000}
            {"schema_version":1,"producer":"forgeplay-wine-runtime","event_code":"darwin_process_started","role":"wineserver","run_identifier":"\(runIdentifier)","prefix_scope":"\(prefixScope)","runtime_fingerprint":"\(runtimeFingerprint)","darwin_pid":42002,"recorded_at_unix_milliseconds":1800000001200,"process_started_at_unix_microseconds":1800000000600000}
            """
        ).utf8)

        XCTAssertEqual(
            SafeProcessRunner.managedWineProcessEvidenceIDs(
                in: data,
                launchSession: launchSession,
                observedAt: registeredAt.addingTimeInterval(2)
            ),
            [42_001, 42_002]
        )

        var ambiguousData = data
        ambiguousData.append(0x0A)
        ambiguousData.append(Data((
            "{\"schema_version\":1," +
            "\"producer\":\"forgeplay-wine-runtime\"," +
            "\"event_code\":\"darwin_process_started\"," +
            "\"role\":\"wine-loader\"," +
            "\"run_identifier\":\"00000000-0000-0000-0000-000000000000\"," +
            "\"prefix_scope\":\"\(prefixScope)\"," +
            "\"runtime_fingerprint\":\"\(runtimeFingerprint)\"," +
            "\"darwin_pid\":42003," +
            "\"recorded_at_unix_milliseconds\":1800000001000," +
            "\"process_started_at_unix_microseconds\":1800000000500000}\n"
        ).utf8))
        XCTAssertTrue(
            SafeProcessRunner.managedWineProcessEvidenceIDs(
                in: ambiguousData,
                launchSession: launchSession,
                observedAt: registeredAt.addingTimeInterval(2)
            ).isEmpty,
            "One foreign record makes the entire per-run ownership file ambiguous."
        )
    }

    func testManagedWineProcessJournalUsesRunScopedUnsandboxedFile() throws {
        let runIdentifier = "3D79C3A0-8D67-4B35-BA7E-644660A1F150"
        let directory = URL(
            fileURLWithPath: "/tmp/ForgePlay/ManagedWineProcessEvidence",
            isDirectory: true
        )

        let evidenceURL = try ManagedWineProcessJournal.evidenceFileURL(
            runIdentifier: runIdentifier,
            fallbackDirectory: directory,
            sandboxEnabled: false
        )

        XCTAssertEqual(
            evidenceURL.path,
            directory.appending(
                path: "3d79c3a0-8d67-4b35-ba7e-644660a1f150.jsonl"
            ).path
        )
    }

    func testLegacyRuntimeIdentityIsAcceptedOnlyForWinePrefixCleanup() {
        XCTAssertTrue(ForgePlayRuntimeCapabilityPolicy.allowsLegacyIdentityForCleanup(
            actionName: "shutdownWinePrefix",
            schemaVersion: 2
        ))
        XCTAssertFalse(ForgePlayRuntimeCapabilityPolicy.allowsLegacyIdentityForCleanup(
            actionName: "shutdownWinePrefix",
            schemaVersion: 1
        ))
        XCTAssertFalse(ForgePlayRuntimeCapabilityPolicy.allowsLegacyIdentityForCleanup(
            actionName: "shutdownWinePrefix",
            schemaVersion: RuntimeManifest.currentSchemaVersion
        ))
        XCTAssertFalse(ForgePlayRuntimeCapabilityPolicy.allowsLegacyIdentityForCleanup(
            actionName: "probeRuntime",
            schemaVersion: 2
        ))
    }

    func testRuntimeCapabilityTechnicalSummaryPreservesIdentityFailureReason() {
        let summary = forgePlayTechnicalErrorSummary(
            ForgePlayRuntimeCapabilityError.bundledRuntimeIdentityIncomplete(
                actionName: "probeRuntime",
                reason: "runtime manifest schema 2 is not release-current"
            )
        )

        XCTAssertTrue(summary.contains("probeRuntime"), summary)
        XCTAssertTrue(summary.contains("schema 2"), summary)
        XCTAssertFalse(summary.contains("ForgePlay.ForgePlayRuntimeCapabilityError"), summary)
    }

    func testSynchronizationContractAlwaysUsesStandardServer() {
        let capabilities = WineSynchronizationRuntimeCapabilities(
            supportedBackends: [.server]
        )

        XCTAssertEqual(WineSynchronizationSelection.allCases, [.automatic])
        XCTAssertEqual(WineSynchronizationBackend.allCases, [.server])
        XCTAssertEqual(capabilities.preferredAutomaticBackend, .server)
        XCTAssertTrue(WineSynchronizationPolicy.automaticServer.isConsistent)
    }

    func testRuntimeSynchronizationCapabilitiesIgnoreLegacyMetadataAndMarkers() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayESyncCapability-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let wineRoot = root.appending(path: "wine", directoryHint: .isDirectory)
        let bin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let ntdllDirectory = wineRoot.appending(
            path: "lib/wine/x86_64-unix",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ntdllDirectory, withIntermediateDirectories: true)

        let launcher = bin.appending(path: "wine")
        let wineserver = bin.appending(path: "wineserver")
        let ntdll = ntdllDirectory.appending(path: "ntdll.so")
        try Data().write(to: launcher)
        let markers = "FORGEPLAY_ESYNC_BACKEND_V1\nFORGEPLAY_ESYNC_SANDBOX_FD_TRANSPORT_V1"
        try Data(markers.utf8).write(to: wineserver)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: wineserver.path
        )
        try Data("ntdll-without-sync-marker".utf8).write(to: ntdll)
        let runtimeInfo = try PropertyListSerialization.data(
            fromPropertyList: [
                "WINEESYNC": true,
                "ForgePlayESyncPolicy": "manual-only",
                "ForgePlayESyncTransport": "server-fd-v1"
            ],
            format: .xml,
            options: 0
        )
        try runtimeInfo.write(to: root.appending(path: "Info.plist"))

        try Data(markers.utf8).write(to: ntdll)
        let capabilities = SafeProcessRunner.wineSynchronizationRuntimeCapabilities(for: launcher)
        XCTAssertEqual(capabilities.supportedBackends, [.server])
        XCTAssertEqual(capabilities.preferredAutomaticBackend, .server)
    }

    func testRunnerEnvironmentRejectsLegacyPrefixSynchronizationBackend() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySyncEnvironment-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let executable = root.appending(path: "wine")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data().write(to: executable)
        try Data(#"{"synchronizationBackend":"msync"}"#.utf8)
            .write(to: prefix.appending(path: "prefix.json"))

        let metadata = prefix.appending(path: "prefix.json")
        XCTAssertThrowsError(
            try SafeProcessRunner.runnerEnvironment(
                for: executable,
                base: ["WINEPREFIX": prefix.path]
            )
        ) { error in
            guard case SafeProcessRunnerError.invalidPrefixSynchronizationProfile(
                let rejectedURL
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(rejectedURL.standardizedFileURL, metadata.standardizedFileURL)
        }
    }

    func testRunnerEnvironmentRejectsLegacyForcedSynchronizationSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySyncEnvironment-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let executable = root.appending(path: "wine")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data().write(to: executable)
        try Data(#"{"synchronizationSelection":"msync","synchronizationBackend":"server"}"#.utf8)
            .write(to: prefix.appending(path: "prefix.json"))

        let metadata = prefix.appending(path: "prefix.json")
        XCTAssertThrowsError(
            try SafeProcessRunner.runnerEnvironment(
                for: executable,
                base: ["WINEPREFIX": prefix.path]
            )
        ) { error in
            guard case SafeProcessRunnerError.invalidPrefixSynchronizationProfile(
                let rejectedURL
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(rejectedURL.standardizedFileURL, metadata.standardizedFileURL)
        }
    }

    func testRunnerActionSandboxCapabilityClassificationIncludesAllActionCases() {
        let executable = URL(fileURLWithPath: "/tmp/ForgePlayRunnerTests/wine")
        let prefix = URL(fileURLWithPath: "/tmp/ForgePlayRunnerTests/Prefix", isDirectory: true)
        let steam = prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
        let installer = URL(fileURLWithPath: "/tmp/ForgePlayRunnerTests/SteamSetup.exe")
        let archive = URL(fileURLWithPath: "/tmp/ForgePlayRunnerTests/runtime.zip")
        let extractionDirectory = URL(fileURLWithPath: "/tmp/ForgePlayRunnerTests/Extracted", isDirectory: true)
        let logs = URL(fileURLWithPath: "/tmp/ForgePlayRunnerTests/Logs", isDirectory: true)
        let supportZip = URL(fileURLWithPath: "/tmp/ForgePlayRunnerTests/support.zip")

        let runtimeActions: [(RunnerAction, String)] = [
            (.initializePrefix(runtimeExecutable: executable, prefix: prefix, logDirectory: logs), "initializePrefix"),
            (.migratePrefixRuntime(runtimeExecutable: executable, prefix: prefix, logDirectory: logs), "migratePrefixRuntime"),
            (.waitForWinePrefix(runtimeExecutable: executable, prefix: prefix, logDirectory: logs), "waitForWinePrefix"),
            (.probeRuntime(executable: executable, logDirectory: logs), "probeRuntime"),
            (.installSteam(runtimeExecutable: executable, prefix: prefix, installer: installer, logDirectory: logs), "installSteam"),
            (.requestSteamClientShutdown(
                runtimeExecutable: executable,
                prefix: prefix,
                steamExecutable: steam,
                logDirectory: logs
            ), "requestSteamClientShutdown"),
            (.shutdownWinePrefix(runtimeExecutable: executable, prefix: prefix, logDirectory: logs), "shutdownWinePrefix"),
            (.launchSteam(
                runtimeExecutable: executable,
                prefix: prefix,
                steamExecutable: steam,
                steamArguments: [],
                graphicsBackend: .d3dMetal,
                logDirectory: logs
            ), "launchSteam"),
            (.launchWindowsUtility(
                runtimeExecutable: executable,
                prefix: prefix,
                executable: prefix.appending(
                    path: "drive_c/Tools/Patcher.exe"
                ),
                logDirectory: logs
            ), "launchWindowsUtility"),
            (.extractRuntimeArchive(
                runtimeExecutable: executable,
                prefix: prefix,
                archive: archive,
                extractionDirectory: extractionDirectory,
                runtime: .vcrun2022,
                logDirectory: logs
            ), "extractRuntimeArchive"),
            (.installRuntime(runtimeExecutable: executable, prefix: prefix, installer: installer, runtime: .vcrun2022, logDirectory: logs), "installRuntime"),
            (.setWindowsVersion(runtimeExecutable: executable, prefix: prefix, version: "win10", logDirectory: logs), "setWindowsVersion"),
            (.setRegistryValue(
                runtimeExecutable: executable,
                prefix: prefix,
                registryPath: "HKLM\\System\\CurrentControlSet\\Services\\winebus",
                valueName: "Enable SDL",
                valueType: "REG_DWORD",
                value: "1",
                logDirectory: logs
            ), "setRegistryValue"),
            (.deleteRegistryValue(
                runtimeExecutable: executable,
                prefix: prefix,
                registryPath:
                    "HKLM\\Software\\NVIDIA Corporation\\Global\\NGXCore",
                valueName: "FullPath",
                logDirectory: logs
            ), "deleteRegistryValue"),
            (.deleteRegistryValueIfPresent(
                runtimeExecutable: executable,
                prefix: prefix,
                registryPath:
                    "HKLM\\Software\\NVIDIA Corporation\\Global\\NGXCore",
                valueName: "FullPath",
                logDirectory: logs
            ), "deleteRegistryValueIfPresent"),
            (.setDLLOverride(runtimeExecutable: executable, prefix: prefix, dll: "d3d11", override: "native,builtin", logDirectory: logs), "setDLLOverride"),
            (.setAppDLLOverride(
                runtimeExecutable: executable,
                prefix: prefix,
                appExecutable: "steam.exe",
                dll: "d3d11",
                override: "native,builtin",
                logDirectory: logs
            ), "setAppDLLOverride"),
            (.deleteAppDLLOverrideIfPresent(
                runtimeExecutable: executable,
                prefix: prefix,
                appExecutable: "steam.exe",
                dll: "d3d11",
                logDirectory: logs
            ), "deleteAppDLLOverrideIfPresent")
        ]

        for (action, actionName) in runtimeActions {
            XCTAssertTrue(action.requiresWindowsRuntime, "\(actionName) must require Windows runner capability")
            XCTAssertEqual(action.capabilityActionName, actionName)
            XCTAssertNotNil(action.windowsRuntimeExecutableURL, "\(actionName) must expose the bundled runtime executable")
            XCTAssertEqual(
                action.requiresManagedWineChildSynchronizationReadback,
                actionName == "launchSteam",
                "only an active Steam provider launch consumes the child synchronization receipt"
            )
        }

        let supportArchive = RunnerAction.createSupportArchive(
            sourceDirectory: prefix,
            destinationZip: supportZip,
            logDirectory: logs
        )
        XCTAssertFalse(supportArchive.requiresWindowsRuntime)
        XCTAssertNil(supportArchive.windowsRuntimeExecutableURL)
        XCTAssertEqual(supportArchive.capabilityActionName, "createSupportArchive")
    }

    func testWindowsUtilityLaunchUsesImmutableSnapshotAndOnlyBaseWineExecutionProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayWindowsUtility-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "wine")
        let prefix = root.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let utility = prefix.appending(
            path: "drive_c/Tools/SecurityModulePatcher.exe"
        )
        let logs = root.appending(
            path: "Logs",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: utility.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try Data("patcher".utf8).write(to: utility)
        try """
        #!/bin/sh
        printf 'arguments=%s\\n' "$*"
        printf 'working_directory=%s\\n' "$PWD"
        printf 'hostile' > "\(utility.path)"
        printf 'live_utility_bytes='
        cat "\(utility.path)"
        printf '\\n'
        printf 'utility_bytes='
        cat "/dev/fd/$FORGEPLAY_BOUND_WINDOWS_UTILITY_EXECUTABLE_FD_V1"
        printf '\\n'
        printf 'renderer=%s\\n' "$FORGEPLAY_GAME_RENDERER_POLICY"
        printf 'renderer_requested=%s\\n' "$FORGEPLAY_GAME_RENDERER_REQUESTED"
        printf 'utility_renderer=%s\\n' "$FORGEPLAY_WINDOWS_UTILITY_RENDERER_BACKEND_V1"
        printf 'network=%s\\n' "$FORGEPLAY_NETWORK_PROFILE_REQUESTED"
        printf 'audio=%s\\n' "$FORGEPLAY_AUDIO_INPUT_MODE"
        printf 'game_mode=%s\\n' "$FORGEPLAY_GAME_MODE_HOST_ENABLED"
        printf 'metalfx=%s\\n' "$D3DM_ENABLE_METALFX"
        printf 'vendor=%s\\n' "$D3DM_VENDOR_ID"
        printf 'streamline=%s\\n' "$SL_LOG_LEVEL"
        printf 'dll_overrides=%s\\n' "$WINEDLLOVERRIDES"
        """.write(
            to: launcher,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )

        let result = try await makeCuratedRuntimeRunner(
            managedWineProcessJournalEnabled: false
        ).run(
            .launchWindowsUtility(
                runtimeExecutable: launcher,
                prefix: prefix,
                executable: utility,
                arguments: ["--repair-security-module"],
                logDirectory: logs
            )
        )
        let output = try String(
            contentsOf: result.stdoutLog,
            encoding: .utf8
        )
        let outputLines = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.actionName, "launchWindowsUtility")
        XCTAssertTrue(
            outputLines.contains {
                $0.hasPrefix("arguments=Z:\\dev\\fd\\") &&
                    $0.hasSuffix(" --repair-security-module")
            },
            output
        )
        let workingDirectoryPrefix = "working_directory="
        let reportedWorkingDirectory = try XCTUnwrap(
            outputLines.first(where: {
                $0.hasPrefix(workingDirectoryPrefix)
            }).map {
                String($0.dropFirst(workingDirectoryPrefix.count))
            }
        )
        var expectedWorkingDirectoryStatus = stat()
        var reportedWorkingDirectoryStatus = stat()
        XCTAssertEqual(
            utility.deletingLastPathComponent().path.withCString {
                Darwin.lstat($0, &expectedWorkingDirectoryStatus)
            },
            0
        )
        XCTAssertEqual(
            reportedWorkingDirectory.withCString {
                Darwin.lstat($0, &reportedWorkingDirectoryStatus)
            },
            0
        )
        XCTAssertEqual(
            reportedWorkingDirectoryStatus.st_dev,
            expectedWorkingDirectoryStatus.st_dev
        )
        XCTAssertEqual(
            reportedWorkingDirectoryStatus.st_ino,
            expectedWorkingDirectoryStatus.st_ino
        )
        XCTAssertTrue(
            outputLines.contains("live_utility_bytes=hostile"),
            output
        )
        XCTAssertTrue(outputLines.contains("utility_bytes=patcher"), output)
        XCTAssertEqual(
            try String(contentsOf: utility, encoding: .utf8),
            "hostile"
        )
        for expected in [
            "renderer=",
            "renderer_requested=",
            "utility_renderer=",
            "network=",
            "audio=",
            "game_mode=",
            "metalfx=",
            "vendor=",
            "streamline=",
            "dll_overrides="
        ] {
            XCTAssertTrue(outputLines.contains(expected), output)
        }
        let evidence = try ProcessRunEvidenceWriter.read(
            from: XCTUnwrap(result.runEvidenceLog)
        )
        XCTAssertEqual(
            evidence.runtimeCompatibility?[
                "windowsUtilityExecutionProfile"
            ],
            "base-runtime"
        )
        XCTAssertEqual(
            evidence.runtimeCompatibility?[
                "windowsUtilityExecutableBinding"
            ],
            "descriptor-sha256-v1"
        )
    }

    func testWindowsUtilityRendererTableReachesSpawnEnvironmentAndEvidence() async throws {
        for (label, backend, component) in [
            (
                "D3DMetal",
                SteamRendererPolicyPreference.d3dMetal,
                "d3dmetal"
            ),
            ("DXMT", SteamRendererPolicyPreference.dxmt, "dxmt"),
            ("D9VK", SteamRendererPolicyPreference.d9vk, "d9vk"),
            ("DXVK", SteamRendererPolicyPreference.vulkan, "dxvk")
        ] {
            let fixture = try makeRendererRoutingFixture(label)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let utility = fixture.prefix.appending(path: "Tool.exe")
            let logs = fixture.root.appending(
                path: "Logs",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: logs,
                withIntermediateDirectories: true
            )
            try Data("utility".utf8).write(to: utility)
            switch backend {
            case .d3dMetal:
                try makeCompleteD3DMetalRenderer(
                    at: fixture.rendererRoot.appending(path: component)
                )
            case .dxmt:
                try makeCompleteDXMTRenderer(
                    at: fixture.rendererRoot.appending(path: component)
                )
            case .d9vk:
                try makeCompleteD9VKRenderer(
                    at: fixture.rendererRoot.appending(path: component)
                )
            case .vulkan:
                try makeCompleteDXVKRenderer(
                    at: fixture.rendererRoot.appending(path: component)
                )
            }
            try """
            #!/bin/sh
            printf 'utility_renderer=%s\\n' "$FORGEPLAY_WINDOWS_UTILITY_RENDERER_BACKEND_V1"
            printf 'dll_overrides=%s\\n' "$WINEDLLOVERRIDES"
            printf 'game_mode=%s\\n' "$FORGEPLAY_GAME_MODE_HOST_ENABLED"
            printf 'network=%s\\n' "$FORGEPLAY_NETWORK_PROFILE_REQUESTED"
            printf 'audio=%s\\n' "$FORGEPLAY_AUDIO_INPUT_MODE"
            printf 'controller=%s\\n' "$FORGEPLAY_CONTROLLER_PROFILE"
            env | while IFS= read -r environment_row; do
                case "$environment_row" in
                    FORGEPLAY_GAME_MODE*)
                        printf 'unexpected_game_mode_key=%s\\n' "$environment_row"
                        ;;
                esac
            done
            """.write(
                to: fixture.launcher,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.launcher.path
            )

            let result = try await makeCuratedRuntimeRunner().run(
                .launchWindowsUtility(
                    runtimeExecutable: fixture.launcher,
                    prefix: fixture.prefix,
                    executable: utility,
                    graphicsBackend: backend,
                    logDirectory: logs
                )
            )
            let output = try String(
                contentsOf: result.stdoutLog,
                encoding: .utf8
            )
            XCTAssertTrue(
                output.contains("utility_renderer=\(backend.rawValue)"),
                output
            )
            XCTAssertTrue(output.contains("dll_overrides="), output)
            XCTAssertTrue(output.contains("game_mode=\n"), output)
            XCTAssertTrue(output.contains("network=\n"), output)
            XCTAssertTrue(output.contains("audio=\n"), output)
            XCTAssertTrue(output.contains("controller=\n"), output)
            XCTAssertFalse(
                output.contains("unexpected_game_mode_key="),
                output
            )
            let evidence = try ProcessRunEvidenceWriter.read(
                from: XCTUnwrap(result.runEvidenceLog)
            )
            XCTAssertEqual(
                evidence.runtimeCompatibility?[
                    "windowsUtilityRendererBackend"
                ],
                backend.rawValue
            )
            XCTAssertEqual(
                evidence.runtimeCompatibility?[
                    "windowsUtilityExecutionProfile"
                ],
                "base-runtime+renderer-\(backend.rawValue)"
            )
        }
    }

    func testWindowsUtilityUnavailableRendererFailsBeforeSpawn() async throws {
        for backend in [
            SteamRendererPolicyPreference.d3dMetal,
            .dxmt,
            .d9vk,
            .vulkan
        ] {
            let fixture = try makeRendererRoutingFixture(
                "UnavailableUtilityRenderer-\(backend.rawValue)"
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let utility = fixture.prefix.appending(path: "Tool.exe")
            let logs = fixture.root.appending(
                path: "Logs",
                directoryHint: .isDirectory
            )
            let marker = fixture.root.appending(path: "spawned")
            try FileManager.default.createDirectory(
                at: logs,
                withIntermediateDirectories: true
            )
            try Data("utility".utf8).write(to: utility)
            try "#!/bin/sh\nprintf started > \"\(marker.path)\"\n".write(
                to: fixture.launcher,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.launcher.path
            )

            do {
                _ = try await makeCuratedRuntimeRunner().run(
                    .launchWindowsUtility(
                        runtimeExecutable: fixture.launcher,
                        prefix: fixture.prefix,
                        executable: utility,
                        graphicsBackend: backend,
                        logDirectory: logs
                    )
                )
                XCTFail(
                    "Unavailable \(backend.rawValue) must fail before spawn"
                )
            } catch {
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: marker.path)
                )
            }
        }
    }

    func testWindowsUtilityLaunchRejectsReplacementAfterDescriptorCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayWindowsUtilityReplacement-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(
            path: "Prefix",
            directoryHint: .isDirectory
        )
        let utility = prefix.appending(path: "drive_c/Tools/Patcher.exe")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let marker = root.appending(path: "runtime-started")
        try FileManager.default.createDirectory(
            at: utility.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try Data("trusted!".utf8).write(to: utility)
        let launcher = try makeMarkerLauncher(in: root, marker: marker)
        let runner = makeCuratedRuntimeRunner(
            managedWineProcessJournalEnabled: false,
            runtimeLaunchObjectIdentityProvider: { _ in
                try FileManager.default.removeItem(at: utility)
                try Data("hostile!".utf8).write(to: utility)
                return nil
            }
        )

        do {
            _ = try await runner.run(
                .launchWindowsUtility(
                    runtimeExecutable: launcher,
                    prefix: prefix,
                    executable: utility,
                    logDirectory: logs
                )
            )
            XCTFail("A utility replaced after capture must not launch")
        } catch let evidenceError as ProcessExecutionEvidenceError {
            guard case SafeProcessRunnerError.unsafeActionInput(let url) =
                    evidenceError.underlyingError else {
                return XCTFail(
                    "Unexpected error: \(evidenceError.underlyingError)"
                )
            }
            XCTAssertEqual(
                url.standardizedFileURL,
                utility.standardizedFileURL
            )
            XCTAssertEqual(evidenceError.result.outcome, .spawnFailed)
            XCTAssertNil(evidenceError.result.processIdentifier)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testWindowsUtilityLaunchRejectsSameInodeContentMutationAfterCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayWindowsUtilityMutation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(
            path: "Prefix",
            directoryHint: .isDirectory
        )
        let utility = prefix.appending(path: "drive_c/Tools/Patcher.exe")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let marker = root.appending(path: "runtime-started")
        try FileManager.default.createDirectory(
            at: utility.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try Data("trusted!".utf8).write(to: utility)
        let launcher = try makeMarkerLauncher(in: root, marker: marker)
        let runner = makeCuratedRuntimeRunner(
            managedWineProcessJournalEnabled: false,
            runtimeLaunchObjectIdentityProvider: { _ in
                let writer = Darwin.open(
                    utility.path,
                    O_WRONLY | O_CLOEXEC | O_NOFOLLOW
                )
                guard writer >= 0 else {
                    throw NSError(
                        domain: "SafeProcessRunnerTests.UtilityMutation",
                        code: Int(errno)
                    )
                }
                defer { Darwin.close(writer) }
                let replacement = Array("hostile!".utf8)
                let written = replacement.withUnsafeBytes { bytes in
                    Darwin.pwrite(
                        writer,
                        bytes.baseAddress,
                        bytes.count,
                        0
                    )
                }
                guard written == replacement.count,
                      Darwin.fsync(writer) == 0 else {
                    throw NSError(
                        domain: "SafeProcessRunnerTests.UtilityMutation",
                        code: Int(errno)
                    )
                }
                return nil
            }
        )

        do {
            _ = try await runner.run(
                .launchWindowsUtility(
                    runtimeExecutable: launcher,
                    prefix: prefix,
                    executable: utility,
                    logDirectory: logs
                )
            )
            XCTFail("An in-place mutated utility must not launch")
        } catch let evidenceError as ProcessExecutionEvidenceError {
            XCTAssertNotEqual(evidenceError.result.outcome, .runningDetached)
            XCTAssertNil(evidenceError.result.processIdentifier)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testManagedWineMaintenanceDoesNotRequireSteamSynchronizationReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayManagedReadbackFailure-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let utility = prefix.appending(path: "drive_c/Tools/Patcher.exe")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let launcher = root.appending(path: "wine")
        let descendantPIDFile = root.appending(path: "descendant.pid")
        var ownedProcessGroup: pid_t?
        var ownedDescendant: pid_t?
        defer {
            if let ownedProcessGroup, ownedProcessGroup > 0 {
                _ = Darwin.kill(-ownedProcessGroup, SIGKILL)
            }
            if let ownedDescendant, ownedDescendant > 0 {
                _ = Darwin.kill(ownedDescendant, SIGKILL)
            }
        }
        try FileManager.default.createDirectory(
            at: utility.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try Data("patcher".utf8).write(to: utility)
        try """
        #!/bin/sh
        (
            trap '' TERM INT
            while :; do sleep 1; done
        ) &
        descendant=$!
        printf '%s' "$descendant" > "\(descendantPIDFile.path)"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        let state = ManagedWineReadbackTestState()
        let runner = makeCuratedRuntimeRunner(
            sandboxEnabled: true,
            managedWineProcessJournalEnabled: false,
            managedWineChildSynchronizationReadbackProvider: {
                processIdentifier in
                state.recordReadback(processIdentifier: processIdentifier)
                throw NSError(
                    domain: "SafeProcessRunnerTests.UnexpectedReadback",
                    code: 91
                )
            }
        )

        let result = try await runner.run(
            .launchWindowsUtility(
                runtimeExecutable: launcher,
                prefix: prefix,
                executable: utility,
                logDirectory: logs
            )
        )
        let processIdentifier = try XCTUnwrap(result.processIdentifier)
        ownedProcessGroup = processIdentifier
        let descendantText = try String(
            contentsOf: descendantPIDFile,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let descendant = try XCTUnwrap(pid_t(descendantText))
        ownedDescendant = descendant

        XCTAssertTrue(result.succeeded)
        XCTAssertNil(result.managedWineChildSynchronizationReadback)
        XCTAssertTrue(state.readbackProcessIdentifiers.isEmpty)
        if let ownedProcessGroup, ownedProcessGroup > 0 {
            _ = Darwin.kill(-ownedProcessGroup, SIGKILL)
            let cleanupDeadline = Date().addingTimeInterval(2)
            while Date() < cleanupDeadline {
                let probe = Darwin.kill(-ownedProcessGroup, 0)
                if probe == -1, errno == ESRCH { break }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        if let ownedDescendant, ownedDescendant > 0 {
            _ = Darwin.kill(ownedDescendant, SIGKILL)
        }
    }

    func testManagedSteamReadbackUsesExactLiveLoaderAfterPrimaryExit() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayManagedReadbackHandoff-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeRoot = root.appending(
            path: "ForgePlayRuntime/wine",
            directoryHint: .isDirectory
        )
        let loader = runtimeRoot.appending(path: "bin/wine.bin")
        let prefix = root.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let evidenceURL = root.appending(path: "managed-wine.jsonl")
        let state = ManagedWineReadbackTestState()
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: loader.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/sleep"),
            to: loader
        )
        let registeredAt = Date()
        let loaderProcess = Process()
        loaderProcess.executableURL = loader
        loaderProcess.arguments = ["60"]
        try loaderProcess.run()
        defer {
            if loaderProcess.isRunning {
                loaderProcess.terminate()
            }
            loaderProcess.waitUntilExit()
        }
        let loaderProcessIdentifier = loaderProcess.processIdentifier
        let loaderStartedAt = try XCTUnwrap(
            ManagedWineProcessJournal.processStartTimeUnixMicroseconds(
                for: loaderProcessIdentifier
            )
        )
        let exitedPrimary = Process()
        exitedPrimary.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exitedPrimary.run()
        exitedPrimary.waitUntilExit()
        let primaryProcessIdentifier = exitedPrimary.processIdentifier
        XCTAssertNotEqual(primaryProcessIdentifier, loaderProcessIdentifier)
        XCTAssertNil(
            ManagedWineProcessJournal.processStartTimeUnixMicroseconds(
                for: primaryProcessIdentifier
            ),
            "the primary fixture must already be exited before loader selection"
        )
        state.recordPrimary(processIdentifier: primaryProcessIdentifier)
        state.recordLoader(processIdentifier: loaderProcessIdentifier)

        let runIdentifier = UUID().uuidString.lowercased()
        let runtimeFingerprint = String(repeating: "a", count: 64)
        let prefixScope = ManagedWineProcessJournal.prefixScope(for: prefix)
        let recordedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        let row =
            "{\"schema_version\":1," +
            "\"producer\":\"forgeplay-wine-runtime\"," +
            "\"event_code\":\"darwin_process_started\"," +
            "\"role\":\"wine-loader\"," +
            "\"run_identifier\":\"\(runIdentifier)\"," +
            "\"prefix_scope\":\"\(prefixScope)\"," +
            "\"runtime_fingerprint\":\"\(runtimeFingerprint)\"," +
            "\"darwin_pid\":\(loaderProcessIdentifier)," +
            "\"recorded_at_unix_milliseconds\":\(recordedAt)," +
            "\"process_started_at_unix_microseconds\":\(loaderStartedAt)}\n"
        try Data(row.utf8).write(to: evidenceURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: evidenceURL.path
        )
        let launchSession = ManagedWineProcessLaunchSession(
            prefixURL: prefix,
            runIdentifier: runIdentifier,
            evidenceURL: evidenceURL,
            runtimeRootURL: runtimeRoot,
            runtimeFingerprint: runtimeFingerprint,
            prefixScope: prefixScope,
            registeredAt: registeredAt
        )

        let runner = makeCuratedRuntimeRunner(
            sandboxEnabled: true,
            managedWineChildSynchronizationReadbackProvider: {
                processIdentifier in
                state.recordReadback(processIdentifier: processIdentifier)
                guard let loaderProcessIdentifier =
                        state.loaderProcessIdentifier,
                      processIdentifier == loaderProcessIdentifier else {
                    throw NSError(
                        domain: "SafeProcessRunnerTests.UnexpectedReadback",
                        code: 92
                    )
                }
                return ManagedWineChildSynchronizationReadback(
                    processIdentifier: processIdentifier,
                    selection: .automatic,
                    backend: .server
                )
            }
        )
        let readback = try await runner.sameSessionManagedWineLoaderReadback(
            for: launchSession,
            primaryProcessIdentifier: primaryProcessIdentifier,
            timeout: 1,
            pollInterval: 0.05
        )
        XCTAssertEqual(
            readback,
            ManagedWineChildSynchronizationReadback(
                processIdentifier: loaderProcessIdentifier,
                selection: .automatic,
                backend: .server
            )
        )
        XCTAssertEqual(
            state.readbackProcessIdentifiers,
            [loaderProcessIdentifier],
            "the exited primary must never receive KERN_PROCARGS2 readback"
        )
    }

    func testDescriptorBoundWaitReapsTermIgnoringDescendantAfterLeaderExit() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayDescriptorWaitLeaderExit-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "ForgePlayRuntime/wine/bin/wine")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let descendantPIDFile = root.appending(path: "descendant.pid")
        var ownedProcessGroup: pid_t?
        var ownedDescendant: pid_t?
        defer {
            if let ownedProcessGroup, ownedProcessGroup > 0 {
                _ = Darwin.kill(-ownedProcessGroup, SIGKILL)
            }
            if let ownedDescendant, ownedDescendant > 0 {
                _ = Darwin.kill(ownedDescendant, SIGKILL)
            }
        }
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        #!/bin/sh
        (
            trap '' TERM INT
            while :; do sleep 1; done
        ) &
        descendant=$!
        printf '%s' "$descendant" > "\(descendantPIDFile.path)"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        try installAuthenticatedRuntimePayloadFixture(for: launcher)
        let runner = makeCuratedRuntimeRunner(
            managedWineProcessJournalEnabled: false,
            runtimeLaunchObjectIdentityProvider: { executable in
                try RuntimeManifestResolver().launchObjectIdentity(
                    for: executable
                )
            }
        )

        let result = try await runner.run(
            .probeRuntime(executable: launcher, logDirectory: logs)
        )
        let processGroup = try XCTUnwrap(result.processIdentifier)
        ownedProcessGroup = processGroup
        let descendantText = try String(
            contentsOf: descendantPIDFile,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let descendant = try XCTUnwrap(pid_t(descendantText))
        ownedDescendant = descendant

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.waitedForExit)
        XCTAssertFalse(result.didTimeOut)
        XCTAssertEqual(result.processExitCode, 0)
        XCTAssertEqual(Darwin.kill(-processGroup, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(Darwin.kill(descendant, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        ownedProcessGroup = nil
        ownedDescendant = nil
    }

    func testDescriptorBoundTimeoutKillsTermIgnoringProcessGroup() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayDescriptorWaitTimeout-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "ForgePlayRuntime/wine/bin/wine")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let descendantPIDFile = root.appending(path: "descendant.pid")
        var ownedProcessGroup: pid_t?
        var ownedDescendant: pid_t?
        defer {
            if let ownedProcessGroup, ownedProcessGroup > 0 {
                _ = Darwin.kill(-ownedProcessGroup, SIGKILL)
            }
            if let ownedDescendant, ownedDescendant > 0 {
                _ = Darwin.kill(ownedDescendant, SIGKILL)
            }
        }
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        #!/bin/sh
        trap '' TERM INT
        (
            trap '' TERM INT
            while :; do sleep 1; done
        ) &
        descendant=$!
        printf '%s' "$descendant" > "\(descendantPIDFile.path)"
        # Keep the initially observed shell live long enough for the parent to
        # bind its exact start identity, then exercise the legitimate exec
        # transition used by the real authenticated Runtime launcher.
        /bin/sleep 1
        exec /bin/zsh -c 'trap "" TERM INT; while :; do /bin/sleep 1; done'
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        try installAuthenticatedRuntimePayloadFixture(for: launcher)
        let runner = makeCuratedRuntimeRunner(
            managedWineProcessJournalEnabled: false,
            runtimeLaunchObjectIdentityProvider: { executable in
                try RuntimeManifestResolver().launchObjectIdentity(
                    for: executable
                )
            }
        )

        let result = try await runner.run(
            .probeRuntime(executable: launcher, logDirectory: logs)
        )
        let processGroup = try XCTUnwrap(result.processIdentifier)
        ownedProcessGroup = processGroup
        let descendantText = try String(
            contentsOf: descendantPIDFile,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let descendant = try XCTUnwrap(pid_t(descendantText))
        ownedDescendant = descendant

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.waitedForExit)
        XCTAssertTrue(result.didTimeOut)
        XCTAssertEqual(Darwin.kill(-processGroup, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(Darwin.kill(descendant, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        ownedProcessGroup = nil
        ownedDescendant = nil
    }

    func testWindowsUtilityLaunchRejectsExecutableOutsideAuthorizedRoots() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayWindowsUtilityBoundary-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let utility = root.appending(path: "Unapproved/Patcher.exe")
        let logs = root.appending(
            path: "Logs",
            directoryHint: .isDirectory
        )
        let marker = root.appending(path: "runtime-started")
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: utility.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try Data("patcher".utf8).write(to: utility)
        let launcher = try makeMarkerLauncher(in: root, marker: marker)

        do {
            _ = try await makeCuratedRuntimeRunner().run(
                .launchWindowsUtility(
                    runtimeExecutable: launcher,
                    prefix: prefix,
                    executable: utility,
                    logDirectory: logs
                )
            )
            XCTFail("An unapproved external utility must not launch")
        } catch let evidenceError as ProcessExecutionEvidenceError {
            guard case SafeProcessRunnerError.unsafeActionInput(let url) =
                    evidenceError.underlyingError else {
                return XCTFail(
                    "Unexpected error: \(evidenceError.underlyingError)"
                )
            }
            XCTAssertEqual(
                url.standardizedFileURL,
                utility.standardizedFileURL
            )
            XCTAssertEqual(
                evidenceError.result.outcome,
                .preflightFailed
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path)
        )
    }

    func testWindowsUtilityLaunchFailsClosedWhenExternalGrantCannotPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayWindowsUtilityGrant-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let externalRoot = root.appending(
            path: "ExternalPatcher",
            directoryHint: .isDirectory
        )
        let utility = externalRoot.appending(path: "Patcher.exe")
        let logs = root.appending(
            path: "Logs",
            directoryHint: .isDirectory
        )
        let marker = root.appending(path: "runtime-started")
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try Data("patcher".utf8).write(to: utility)
        let launcher = try makeMarkerLauncher(in: root, marker: marker)
        let runner = makeCuratedRuntimeRunner(
            sandboxEnabled: true,
            externalStorageGrantPublisher: { _, _, _ in
                throw NSError(
                    domain:
                        "SafeProcessRunnerTests.WindowsUtilityGrant",
                    code: 37
                )
            }
        )

        do {
            _ = try await runner.run(
                .launchWindowsUtility(
                    runtimeExecutable: launcher,
                    prefix: prefix,
                    executable: utility,
                    logDirectory: logs,
                    externalStorageRoots: [externalRoot]
                )
            )
            XCTFail("The utility must not launch without its required grant")
        } catch let evidenceError as ProcessExecutionEvidenceError {
            let error = evidenceError.underlyingError as NSError
            XCTAssertEqual(
                error.domain,
                "SafeProcessRunnerTests.WindowsUtilityGrant"
            )
            XCTAssertEqual(error.code, 37)
            XCTAssertEqual(
                evidenceError.result.outcome,
                .preflightFailed
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path)
        )
    }

    func testDiagnosticSourceLogsPreferDiagnosticLogBeforeRawProcessLogs() {
        let root = URL(fileURLWithPath: "/tmp/ForgePlayRunnerTests-\(UUID().uuidString)", isDirectory: true)
        let stdout = root.appending(path: "stdout.log")
        let stderr = root.appending(path: "stderr.log")
        let diagnostics = root.appending(path: "stderr.diagnostics.log")
        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: root.appending(path: "wine"),
            arguments: [],
            startedAt: Date(),
            endedAt: Date(),
            exitCode: 71,
            stdoutLog: stdout,
            stderrLog: stderr,
            diagnosticLog: diagnostics,
            didTimeOut: false
        )

        XCTAssertEqual(result.diagnosticSourceLogs, [diagnostics, stderr, stdout])
    }

    func testProcessRunSidecarDecodesCompleteExecutionEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayProcessEvidenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "wine")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf 'probe-output\\n'\nprintf 'probe-error\\n' >&2\nexit 7\n"
            .write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let result = try await makeCuratedRuntimeRunner().run(.probeRuntime(
            executable: launcher,
            logDirectory: logs
        ))
        let evidenceURL = try XCTUnwrap(result.runEvidenceLog)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(
            ProcessRunEvidenceDocument.self,
            from: Data(contentsOf: evidenceURL)
        )

        XCTAssertEqual(result.outcome, .exited)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.evidenceCaptureWarning)
        XCTAssertEqual(document.schemaVersion, ProcessRunEvidenceDocument.schemaVersion)
        XCTAssertNotNil(document.hostContext)
        XCTAssertFalse(document.hostContext?.operatingSystemVersion.isEmpty ?? true)
        XCTAssertGreaterThan(document.hostContext?.physicalMemoryBytes ?? 0, 0)
        XCTAssertEqual(document.actionName, "probeBundledRuntime")
        XCTAssertEqual(document.executable, launcher.path)
        XCTAssertEqual(document.arguments, ["--version"])
        XCTAssertEqual(document.outcome, .exited)
        XCTAssertEqual(document.exitCode, 7)
        XCTAssertFalse(document.didTimeOut)
        XCTAssertTrue(document.waitedForExit)
        XCTAssertNotNil(document.processIdentifier)
        XCTAssertEqual(document.stdoutLog, result.stdoutLog.path)
        XCTAssertEqual(document.stderrLog, result.stderrLog.path)
        XCTAssertEqual(document.rawWaitStatus, result.rawWaitStatus)
        XCTAssertGreaterThanOrEqual(document.durationMilliseconds, 0)
        XCTAssertNotNil(document.finalizedAt)
        XCTAssertNil(document.evidenceCaptureWarning)
        XCTAssertNotNil(UUID(uuidString: document.runIdentifier))
        XCTAssertTrue(evidenceURL.lastPathComponent.hasSuffix("_stderr.run.json"))
    }

    func testStrictRuntimeIdentityRunsAuthenticatedShellLauncherWithOriginalArguments() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayStrictShellRuntime-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "wine/bin/wine")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try """
        #!/bin/sh
        printf 'argv0=%s\\n' "$0"
        printf 'argc=%s\\n' "$#"
        printf 'arg1=%s\\n' "$1"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        try installAuthenticatedRuntimePayloadFixture(for: launcher)

        let result = try await SafeProcessRunner(
            sandboxEnabled: false,
            managedWineProcessEvidenceSandboxEnabled: false,
            windowsRuntimeValidator: { _, _ in }
        ).run(.probeRuntime(
            executable: launcher,
            logDirectory: logs
        ))
        let output = try String(contentsOf: result.stdoutLog, encoding: .utf8)

        XCTAssertTrue(result.succeeded, output)
        XCTAssertEqual(result.processExitCode, 0)
        XCTAssertEqual(
            output.split(whereSeparator: \.isNewline).map(String.init),
            [
                "argv0=\(launcher.path)",
                "argc=1",
                "arg1=--version"
            ]
        )
    }

    func testFailedSilentProcessReceivesReadableDiagnosticSummary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySilentFailure-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "wine")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 7\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )

        let result = try await makeCuratedRuntimeRunner().run(.probeRuntime(
            executable: launcher,
            logDirectory: logs
        ))
        let stderr = try String(contentsOf: result.stderrLog, encoding: .utf8)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(stderr.contains("[ForgePlay] Process execution summary"), stderr)
        XCTAssertTrue(stderr.contains("[ForgePlay] Process exit: 7"), stderr)
        XCTAssertTrue(stderr.contains("[ForgePlay] Structured run evidence:"), stderr)
        XCTAssertEqual(result.preferredDiagnosticLog, result.stderrLog)
    }

    func testProcessEvidenceFinalizationAtomicallyPersistsFinalWarningsAndLinks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayProcessFinalizationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let runID = UUID().uuidString.lowercased()
        let stdout = root.appending(path: "launch_\(runID)_stdout.log")
        let stderr = root.appending(path: "launch_\(runID)_stderr.log")
        let diagnostics = root.appending(path: "launch_\(runID)_diagnostics.log")
        let relatedEvidence = root.appending(path: "related.run.json")
        for url in [stdout, stderr, diagnostics] {
            try Data().write(to: url)
        }
        let evidenceURL = ProcessRunEvidenceWriter.evidenceURL(for: stderr)
        let startedAt = Date().addingTimeInterval(-2)
        let endedAt = Date().addingTimeInterval(-1)
        let initialDocument = ProcessRunEvidenceDocument(
            hostContext: nil,
            runIdentifier: runID,
            actionName: "launchSteam",
            executable: "/usr/bin/true",
            arguments: [],
            environmentOverrides: [:],
            workingDirectory: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMilliseconds: 1_000,
            outcome: .runningDetached,
            exitCode: nil,
            terminationSignal: nil,
            rawWaitStatus: nil,
            didTimeOut: false,
            waitedForExit: false,
            processIdentifier: 42,
            stdoutLog: stdout.path,
            stderrLog: stderr.path,
            processObservationLog: nil,
            captureError: nil
        )
        try ProcessRunEvidenceWriter.write(initialDocument, to: evidenceURL)

        let result = ProcessRunResult(
            actionName: "launchSteam",
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            startedAt: startedAt,
            endedAt: endedAt,
            exitCode: 0,
            hasProcessExitCode: false,
            forgePlayStatusCode: 74,
            stdoutLog: stdout,
            stderrLog: stderr,
            diagnosticLog: diagnostics,
            didTimeOut: false,
            waitedForExit: false,
            outcome: .runningDetached,
            processIdentifier: 42,
            runEvidenceLog: evidenceURL,
            relatedRunEvidenceLogs: [relatedEvidence],
            evidenceCaptureWarning: "Process exit status capture failed: forced waitpid ECHILD",
            diagnosticCaptureWarning: "diagnostic evidence incomplete"
        )

        let finalized = await makeCuratedRuntimeRunner().finalizeProcessEvidence(result)
        let document = try ProcessRunEvidenceWriter.read(from: evidenceURL)

        XCTAssertEqual(finalized.evidenceCaptureWarning, result.evidenceCaptureWarning)
        XCTAssertEqual(document.forgePlayStatusCode, 74)
        XCTAssertEqual(document.diagnosticLog, diagnostics.path)
        XCTAssertEqual(document.relatedRunEvidenceLogs, [relatedEvidence.path])
        XCTAssertEqual(document.evidenceCaptureWarning, result.evidenceCaptureWarning)
        XCTAssertEqual(document.diagnosticCaptureWarning, result.diagnosticCaptureWarning)
        XCTAssertNotNil(document.finalizedAt)
        XCTAssertNotNil(document.activityLeaseExpiresAt)
    }

    func testRunnerRejectsUnsafeExecutablesAtProcessBoundary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let realLauncher = root.appending(path: "real-wine")
        let linkedLauncher = root.appending(path: "wine")
        let hardlinkSource = root.appending(path: "hardlink-source-wine")
        let hardlinkedLauncher = root.appending(path: "hardlinked-wine")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: realLauncher, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: hardlinkSource, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realLauncher.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hardlinkSource.path)
        try FileManager.default.createSymbolicLink(at: linkedLauncher, withDestinationURL: realLauncher)
        try FileManager.default.linkItem(at: hardlinkSource, to: hardlinkedLauncher)

        var expectedFailures: [(executable: URL, error: NSError, summary: String, result: ProcessRunResult)] = []
        for executable in [linkedLauncher, hardlinkedLauncher] {
            do {
                _ = try await makeCuratedRuntimeRunner().run(.probeRuntime(
                    executable: executable,
                    logDirectory: logs
                ))
                XCTFail("Expected unsafe executable to be rejected at the runner boundary: \(executable.path)")
            } catch let evidenceError as ProcessExecutionEvidenceError {
                guard let error = evidenceError.underlyingError as? SafeProcessRunnerError,
                      case .unsafeExecutable(let url) = error else {
                    return XCTFail("Unexpected underlying error: \(evidenceError.underlyingError)")
                }
                XCTAssertEqual(url.standardizedFileURL.path, executable.standardizedFileURL.path)
                XCTAssertEqual(evidenceError.result.outcome, .preflightFailed)
                XCTAssertFalse(evidenceError.result.hasProcessExitCode)
                XCTAssertNil(evidenceError.result.processIdentifier)
                XCTAssertNotNil(evidenceError.result.runEvidenceLog)
                XCTAssertEqual(diagnosticProcessRunResult(from: evidenceError), evidenceError.result)
                expectedFailures.append((
                    executable,
                    error as NSError,
                    forgePlayTechnicalErrorSummary(error),
                    evidenceError.result
                ))
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        let evidenceURLs = try FileManager.default.contentsOfDirectory(
            at: logs,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix("_stderr.run.json") }
        XCTAssertEqual(evidenceURLs.count, expectedFailures.count)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let documents = try evidenceURLs.map {
            try decoder.decode(ProcessRunEvidenceDocument.self, from: Data(contentsOf: $0))
        }
        for expected in expectedFailures {
            let document = try XCTUnwrap(documents.first {
                $0.executable == expected.executable.path
            })
            XCTAssertEqual(document.actionName, "probeRuntime:preflight")
            XCTAssertEqual(document.outcome, .preflightFailed)
            XCTAssertFalse(document.waitedForExit)
            XCTAssertNil(document.processIdentifier)
            XCTAssertEqual(document.failureDomain, expected.error.domain)
            XCTAssertEqual(document.failureCode, expected.error.code)
            XCTAssertTrue(document.captureError?.contains(expected.summary) == true)
            XCTAssertNil(document.exitCode)
            XCTAssertTrue(document.stderrLog.contains("probeRuntime_preflight"), document.stderrLog)
            XCTAssertEqual(expected.result.runEvidenceLog?.standardizedFileURL.path, evidenceURLs.first {
                $0.standardizedFileURL.path == ProcessRunEvidenceWriter.evidenceURL(
                    for: expected.result.stderrLog
                ).standardizedFileURL.path
            }?.standardizedFileURL.path)
        }
    }

    func testCompositeCleanupErrorPreservesAllProcessEvidenceAndNoInventedExitStatus() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCompositeEvidence-\(UUID().uuidString)", directoryHint: .isDirectory)
        let now = Date()
        let original = ProcessRunResult(
            actionName: "installRuntime:preflight",
            executable: root.appending(path: "unresolved"),
            arguments: [],
            startedAt: now,
            endedAt: now,
            exitCode: 1,
            hasProcessExitCode: false,
            stdoutLog: root.appending(path: "original_stdout.log"),
            stderrLog: root.appending(path: "original_stderr.log"),
            didTimeOut: false,
            waitedForExit: false,
            outcome: .preflightFailed
        )
        let cleanup = ProcessRunResult(
            actionName: "shutdownWinePrefix",
            executable: root.appending(path: "wineserver"),
            arguments: ["-k"],
            startedAt: now,
            endedAt: now,
            exitCode: 37,
            stdoutLog: root.appending(path: "cleanup_stdout.log"),
            stderrLog: root.appending(path: "cleanup_stderr.log"),
            didTimeOut: false,
            outcome: .exited
        )
        let composite = SteamPrefixLifecycleCleanupError(
            originalDescription: "runtime preparation failed",
            cleanupDescription: "cleanup exited 37",
            originalProcessResult: original,
            cleanupProcessResults: [cleanup]
        )

        XCTAssertNil(original.processExitCode)
        XCTAssertFalse(original.succeeded)
        XCTAssertEqual(cleanup.processExitCode, 37)
        XCTAssertEqual(
            diagnosticProcessRunResults(from: composite).map(\.actionName),
            ["installRuntime:preflight", "shutdownWinePrefix"]
        )
        XCTAssertEqual(diagnosticProcessRunResult(from: composite), original)
    }

    func testRunnerRejectsSymlinkLogDirectoryAtProcessBoundary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLogs = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalLogs-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalLogs)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalLogs, withIntermediateDirectories: true)
        let linkedLogs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: linkedLogs, withDestinationURL: externalLogs)

        let launcher = root.appending(path: "wine")
        try "#!/bin/sh\nprintf 'should not run'\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        do {
            _ = try await makeCuratedRuntimeRunner().run(.probeRuntime(
                executable: launcher,
                logDirectory: linkedLogs
            ))
            XCTFail("Expected symlink log directory to be rejected")
        } catch SafeProcessRunnerError.cannotCreateLog(let url) {
            XCTAssertTrue(url.path.hasPrefix(linkedLogs.path))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: externalLogs.path).isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunnerRejectsSymlinkPrefixBeforeExternalCommand() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalPrefix = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalPrefix-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalPrefix)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalPrefix, withIntermediateDirectories: true)
        let linkedPrefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: linkedPrefix, withDestinationURL: externalPrefix)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let marker = root.appending(path: "runner-called")
        let launcher = try makeMarkerLauncher(in: root, marker: marker)

        var expectedError: NSError?
        var expectedSummary: String?
        do {
            _ = try await makeCuratedRuntimeRunner().run(.initializePrefix(
                runtimeExecutable: launcher,
                prefix: linkedPrefix,
                logDirectory: logs
            ))
            XCTFail("Expected symlink prefix to be rejected before external command")
        } catch let evidenceError as ProcessExecutionEvidenceError {
            guard let error = evidenceError.underlyingError as? SafeProcessRunnerError,
                  case .unsafeActionInput(let url) = error else {
                return XCTFail("Unexpected underlying error: \(evidenceError.underlyingError)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, linkedPrefix.standardizedFileURL.path)
            XCTAssertEqual(evidenceError.result.outcome, .preflightFailed)
            XCTAssertFalse(evidenceError.result.hasProcessExitCode)
            XCTAssertNotNil(evidenceError.result.runEvidenceLog)
            expectedError = error as NSError
            expectedSummary = forgePlayTechnicalErrorSummary(error)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        let evidenceURLs = try FileManager.default.contentsOfDirectory(
            at: logs,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix("_stderr.run.json") }
        XCTAssertEqual(evidenceURLs.count, 1)
        let evidenceURL = try XCTUnwrap(evidenceURLs.first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(
            ProcessRunEvidenceDocument.self,
            from: Data(contentsOf: evidenceURL)
        )
        let bridgedError = try XCTUnwrap(expectedError)

        XCTAssertEqual(document.actionName, "initializePrefix:preflight")
        XCTAssertEqual(document.executable, launcher.path)
        XCTAssertEqual(document.outcome, .preflightFailed)
        XCTAssertNil(document.exitCode)
        XCTAssertFalse(document.waitedForExit)
        XCTAssertNil(document.processIdentifier)
        XCTAssertEqual(document.failureDomain, bridgedError.domain)
        XCTAssertEqual(document.failureCode, bridgedError.code)
        XCTAssertTrue(document.captureError?.contains(try XCTUnwrap(expectedSummary)) == true)
        XCTAssertTrue(document.stderrLog.contains("initializePrefix_preflight"), document.stderrLog)
    }

    func testRunnerRejectsHardlinkedRuntimeInstallerBeforeExternalCommand() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let installerSource = root.appending(path: "source-xnafx40_redist.msi")
        let hardlinkedInstaller = root.appending(path: "xnafx40_redist.msi")
        try Data("installer".utf8).write(to: installerSource)
        try FileManager.default.linkItem(at: installerSource, to: hardlinkedInstaller)
        let marker = root.appending(path: "runtime-runner-called")
        let launcher = try makeMarkerLauncher(in: root, marker: marker)

        do {
            _ = try await makeCuratedRuntimeRunner().run(.installRuntime(
                runtimeExecutable: launcher,
                prefix: prefix,
                installer: hardlinkedInstaller,
                runtime: .xna40,
                logDirectory: logs
            ))
            XCTFail("Expected hardlinked runtime installer to be rejected before external command")
        } catch let evidenceError as ProcessExecutionEvidenceError {
            guard let error = evidenceError.underlyingError as? SafeProcessRunnerError,
                  case .unsafeActionInput(let url) = error else {
                return XCTFail("Unexpected underlying error: \(evidenceError.underlyingError)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, hardlinkedInstaller.standardizedFileURL.path)
            XCTAssertEqual(evidenceError.result.outcome, .preflightFailed)
            XCTAssertFalse(evidenceError.result.hasProcessExitCode)
            XCTAssertNotNil(evidenceError.result.runEvidenceLog)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testShutdownWinePrefixTreatsCleanPrefixAsSuccessWhenWineserverReturnsNoServerExit() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"),
            "Prefix cleanup verification requires lsof on macOS."
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let launcher = try makeWineRunner(
            in: root,
            wineserverScript: "#!/bin/sh\n[ \"${1:-}\" = \"-w\" ] && exit 0\nexit 1\n"
        )
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let result = try await makeCuratedRuntimeRunner().run(.shutdownWinePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let stderr = try String(contentsOf: result.stderrLog, encoding: .utf8)

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(stderr.contains("wineserver reported no active server"))
    }

    func testSandboxShutdownTreatsEmptyNoServerExitAsSuccessWithoutHostProcessInspection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySandboxShutdown-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let launcher = try makeWineRunner(
            in: root,
            wineserverScript: "#!/bin/sh\n[ \"${1:-}\" = \"-w\" ] && exit 0\nexit 1\n"
        )
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let result = try await makeCuratedRuntimeRunner(sandboxEnabled: true).run(.shutdownWinePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let stderr = try String(contentsOf: result.stderrLog, encoding: .utf8)

        XCTAssertTrue(result.succeeded, stderr)
        XCTAssertTrue(stderr.contains("wineserver reported no active server"), stderr)
        XCTAssertFalse(stderr.contains("Could not verify Wine prefix process cleanup"), stderr)
    }

    func testSandboxShutdownPreservesNoServerExitWhenWineserverReportsError() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySandboxShutdownError-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let launcher = try makeWineRunner(
            in: root,
            wineserverScript: "#!/bin/sh\nprintf 'simulated wineserver failure\\n' >&2\nexit 1\n"
        )
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let result = try await makeCuratedRuntimeRunner(sandboxEnabled: true).run(.shutdownWinePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let stderr = try String(contentsOf: result.stderrLog, encoding: .utf8)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(stderr.contains("simulated wineserver failure"), stderr)
        XCTAssertFalse(stderr.contains("Treating the prefix as clean"), stderr)
    }

    func testShutdownWinePrefixFailsWhenWineserverExitBarrierFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayShutdownBarrier-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let launcher = try makeWineRunner(
            in: root,
            wineserverScript: """
            #!/bin/sh
            if [ "${1:-}" = "-w" ]; then
              printf 'simulated shutdown barrier failure\n' >&2
              exit 9
            fi
            exit 0
            """
        )
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let result = try await makeCuratedRuntimeRunner(sandboxEnabled: true).run(.shutdownWinePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let stderr = try String(contentsOf: result.stderrLog, encoding: .utf8)

        XCTAssertEqual(result.processExitCode, 0)
        XCTAssertEqual(result.forgePlayStatusCode, 9)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(stderr.contains("Wine prefix shutdown barrier failed"), stderr)
        XCTAssertTrue(stderr.contains("remained unconfirmed after forced recovery"), stderr)
        XCTAssertEqual(result.outcome, .exited)
        XCTAssertEqual(result.relatedRunEvidenceLogs.count, 3)
        XCTAssertTrue(result.relatedRunEvidenceLogs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
    }

    func testShutdownWinePrefixRecoversWithForcedStopAndSecondBarrier() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayShutdownRecovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let firstBarrierMarker = root.appending(path: "first-barrier-failed")
        let launcher = try makeWineRunner(
            in: root,
            wineserverScript: """
            #!/bin/sh
            if [ "${1:-}" = "-w" ] && [ ! -f "\(firstBarrierMarker.path)" ]; then
              touch "\(firstBarrierMarker.path)"
              exit 9
            fi
            exit 0
            """
        )
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let result = try await makeCuratedRuntimeRunner(sandboxEnabled: true).run(.shutdownWinePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let stderr = try String(contentsOf: result.stderrLog, encoding: .utf8)

        XCTAssertTrue(result.succeeded, stderr)
        XCTAssertEqual(result.postconditionSatisfied, true)
        XCTAssertTrue(stderr.contains("Forced shutdown recovery completed"), stderr)
        XCTAssertEqual(result.relatedRunEvidenceLogs.count, 3)
    }

    func testPostconditionSuccessPreservesTimedOutPrimaryAttempt() {
        let root = URL(fileURLWithPath: "/tmp/ForgePlayPostcondition-\(UUID().uuidString)")
        let result = ProcessRunResult(
            actionName: "shutdownWinePrefix",
            executable: root.appending(path: "wineserver"),
            arguments: ["--kill=15"],
            startedAt: Date(),
            endedAt: Date(),
            exitCode: 137,
            hasProcessExitCode: false,
            forgePlayStatusCode: 0,
            stdoutLog: root.appending(path: "stdout.log"),
            stderrLog: root.appending(path: "stderr.log"),
            didTimeOut: true,
            outcome: .timedOut,
            terminationSignal: SIGKILL,
            postconditionSatisfied: true
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.didTimeOut)
        XCTAssertEqual(result.terminationSignal, SIGKILL)
        XCTAssertNil(result.processExitCode)
    }

    func testSafeProcessRunnerErrorKeepsTechnicalFailureDetails() {
        let prefix = URL(fileURLWithPath: "/tmp/ForgePlay Prefix", isDirectory: true)
        let summary = forgePlayTechnicalErrorSummary(
            SafeProcessRunnerError.prefixProcessVerificationFailed(prefix, "sandbox denied process inspection")
        )

        XCTAssertTrue(summary.contains(prefix.path), summary)
        XCTAssertTrue(summary.contains("sandbox denied process inspection"), summary)
    }

    func testVerifiedManagedWineProcessIdentitiesRequireExactCurrentRunSession() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayExactManagedRun-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let runtimeRoot = root.appending(
            path: "ForgePlayRuntime/wine",
            directoryHint: .isDirectory
        )
        let executable = runtimeRoot.appending(
            path: "bin/wine.bin",
            directoryHint: .notDirectory
        )
        let evidenceURL = root.appending(
            path: "managed-wine.jsonl",
            directoryHint: .notDirectory
        )
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/sleep"),
            to: executable
        )
        let process = Process()
        process.executableURL = executable
        process.arguments = ["60"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        let processID = process.processIdentifier
        let startedAt = try XCTUnwrap(
            ManagedWineProcessJournal.processStartTimeUnixMicroseconds(
                for: processID
            )
        )
        let runIdentifier = UUID().uuidString.lowercased()
        let runtimeFingerprint = String(repeating: "a", count: 64)
        let prefixScope = ManagedWineProcessJournal.prefixScope(for: prefix)
        let recordedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        let record =
            "{\"schema_version\":1," +
            "\"producer\":\"forgeplay-wine-runtime\"," +
            "\"event_code\":\"darwin_process_started\"," +
            "\"role\":\"wine-loader\"," +
            "\"run_identifier\":\"\(runIdentifier)\"," +
            "\"prefix_scope\":\"\(prefixScope)\"," +
            "\"runtime_fingerprint\":\"\(runtimeFingerprint)\"," +
            "\"darwin_pid\":\(processID)," +
            "\"recorded_at_unix_milliseconds\":\(recordedAt)," +
            "\"process_started_at_unix_microseconds\":\(startedAt)}\n"
        try Data(record.utf8).write(to: evidenceURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: evidenceURL.path
        )
        let registry = ManagedWineSessionRegistry()
        registry.record(ManagedWineProcessLaunchSession(
            prefixURL: prefix,
            runIdentifier: runIdentifier,
            evidenceURL: evidenceURL,
            runtimeRootURL: runtimeRoot,
            runtimeFingerprint: runtimeFingerprint,
            prefixScope: prefixScope,
            registeredAt: Date()
        ))
        let runner = makeCuratedRuntimeRunner(
            sandboxEnabled: true,
            managedWineSessionRegistry: registry
        )

        let verifiedIdentities = try await runner
            .verifiedManagedWineProcessIdentities(
                under: prefix,
                runIdentifier: runIdentifier
            )
        XCTAssertEqual(
            verifiedIdentities,
            [
                ManagedWineLaunchProcessIdentity(
                    processID: processID,
                    processStartedAtUnixMicroseconds: startedAt,
                    executableURL: executable.standardizedFileURL
                        .resolvingSymlinksInPath()
                )
            ]
        )
        do {
            _ = try await runner.verifiedManagedWineProcessIdentities(
                under: prefix,
                runIdentifier: UUID().uuidString.lowercased()
            )
            XCTFail("a foreign run identifier must not inherit this session")
        } catch {
            XCTAssertTrue(
                forgePlayTechnicalErrorSummary(error)
                    .contains("exact managed Wine launch session")
            )
        }
    }

    func testSandboxManagedPrefixActivityIgnoresWindowsObservationJournal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCompletedLaunch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "wine")
        let prefix = root.appending(path: "Prefixes/SteamShared", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        let steamExecutable = steamDirectory.appending(path: "steam.exe")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data().write(to: steamExecutable)
        try makeManagedD3DMetalRenderer(for: prefix)
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let runner = makeCuratedRuntimeRunner(
            sandboxEnabled: true,
            managedWineProcessJournalEnabled: false
        )
        let result = try await runner.run(.launchSteam(
            runtimeExecutable: launcher,
            prefix: prefix,
            steamExecutable: steamExecutable,
            steamArguments: [],
            graphicsBackend: .d3dMetal,
            logDirectory: logs
        ))

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.waitedForExit)
        let hasActivity = try await runner.hasManagedPrefixActivity(prefix)
        XCTAssertFalse(hasActivity)

        let observationLog = try XCTUnwrap(result.processObservationLog)
        try Data("FORGEPLAY_PROCESS_V1\t99999\tpartial".utf8).write(to: observationLog)
        let hasActivityAfterPartialWindowsRecord = try await runner.hasManagedPrefixActivity(prefix)
        XCTAssertFalse(hasActivityAfterPartialWindowsRecord)
    }

    func testArmedGameModeRouteWithoutRoutedGameChildDoesNotObstructSteamLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayArmedGameModeRoute-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "wine")
        let prefix = root.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let steamDirectory = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        let steamExecutable = steamDirectory.appending(path: "steam.exe")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: steamDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try Data().write(to: steamExecutable)
        try makeManagedD3DMetalRenderer(for: prefix)
        try "#!/bin/sh\nexit 0\n".write(
            to: launcher,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )

        let applicationGroupIdentifier = "group.com.forgeplay.tests"
        let applicationGroupContainer = root.appending(
            path: "GameModeApplicationGroup",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: applicationGroupContainer,
            withIntermediateDirectories: true
        )
        let gameModeEvidenceLog = applicationGroupContainer
            .appending(
                path: "Library/Application Support/ForgePlay",
                directoryHint: .isDirectory
            )
            .appending(
                path: GameModeHostCoordinationPaths.evidenceDirectoryName,
                directoryHint: .isDirectory
            )
            .appending(
                path: GameModeHostCoordinationPaths.evidenceFileName,
                directoryHint: .notDirectory
            )

        let runner = makeCuratedRuntimeRunner(
            sandboxEnabled: true,
            managedWineProcessJournalEnabled: false,
            gameModeHostApplicationGroupIdentifier:
                applicationGroupIdentifier,
            gameModeHostApplicationGroupContainerResolver: { identifier in
                guard identifier == applicationGroupIdentifier else {
                    return nil
                }
                return applicationGroupContainer
            }
        )

        func launchSteamWithArmedGameModeRoute() async throws
            -> ProcessRunResult {
            try await runner.run(.launchSteam(
                runtimeExecutable: launcher,
                prefix: prefix,
                steamExecutable: steamExecutable,
                steamArguments: [],
                graphicsBackend: .d3dMetal,
                gameModePolicy: .experimentalRequiredHost,
                logDirectory: logs
            ))
        }

        let launchWithoutGameChild = try await
            launchSteamWithArmedGameModeRoute()
        XCTAssertTrue(launchWithoutGameChild.succeeded)
        let hasActivityWithoutGameChild = try await runner
            .hasManagedPrefixActivity(prefix)
        XCTAssertFalse(hasActivityWithoutGameChild)

        let firstShutdown = try await runner.run(.shutdownWinePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let firstShutdownStderr = try String(
            contentsOf: firstShutdown.stderrLog,
            encoding: .utf8
        )
        XCTAssertTrue(firstShutdown.succeeded, firstShutdownStderr)
        XCTAssertEqual(firstShutdown.postconditionSatisfied, true)

        _ = try await launchSteamWithArmedGameModeRoute()
        try Data((
            """
            {"schema_version":1,"producer":"game-mode-process-host","event_code":"wine_main_entered","recorded_at_unix_milliseconds":1800000001000,"darwin_pid":42001,"process_started_at_unix_microseconds":1800000000500000,"run_identifier":"00000000-0000-0000-0000-000000000000"}
            """ + "\n"
        ).utf8).write(to: gameModeEvidenceLog, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: gameModeEvidenceLog.path
        )

        let hasActivityWithUnrelatedEvidence = try await runner
            .hasManagedPrefixActivity(prefix)
        XCTAssertFalse(hasActivityWithUnrelatedEvidence)
        let secondShutdown = try await runner.run(.shutdownWinePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let secondShutdownStderr = try String(
            contentsOf: secondShutdown.stderrLog,
            encoding: .utf8
        )
        XCTAssertTrue(secondShutdown.succeeded, secondShutdownStderr)
        XCTAssertEqual(secondShutdown.postconditionSatisfied, true)
    }

    func testSandboxManagedPrefixActivityDoesNotTreatWindowsPIDAsDarwinProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayObservedActivity-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "wine")
        let prefix = root.appending(path: "Prefixes/SteamShared", directoryHint: .isDirectory)
        let siblingPrefix = root.appending(path: "SiblingPrefix", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        let steamExecutable = steamDirectory.appending(path: "steam.exe")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let observedProcessIDFile = root.appending(path: "observed-process-id.txt")
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingPrefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data().write(to: steamExecutable)
        try makeManagedD3DMetalRenderer(for: prefix)
        try """
        #!/bin/sh
        /bin/sleep 60 &
        observed_pid=$!
        printf '%s' "$observed_pid" > "\(observedProcessIDFile.path)"
        observation_path="${FORGEPLAY_PROCESS_OBSERVATION_FILE#Z:}"
        observation_path="$(printf '%s' "$observation_path" | tr '\\' '/')"
        printf '%s\t%s\t%s\n' \
          'FORGEPLAY_PROCESS_V1' \
          "$observed_pid" \
          'C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win7x64\\steamwebhelper.exe --no-sandbox' \
          >> "$observation_path"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let runner = makeCuratedRuntimeRunner(
            sandboxEnabled: true,
            managedWineProcessJournalEnabled: false
        )
        let result = try await runner.run(.launchSteam(
            runtimeExecutable: launcher,
            prefix: prefix,
            steamExecutable: steamExecutable,
            steamArguments: [],
            graphicsBackend: .d3dMetal,
            logDirectory: logs
        ))
        let observedProcessID = try XCTUnwrap(
            pid_t(
                String(contentsOf: observedProcessIDFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        defer { _ = Darwin.kill(observedProcessID, SIGKILL) }

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.waitedForExit)
        let hasObservedActivity = try await runner.hasManagedPrefixActivity(prefix)
        let hasSiblingActivity = try await runner.hasManagedPrefixActivity(siblingPrefix)
        XCTAssertFalse(hasObservedActivity)
        XCTAssertFalse(hasSiblingActivity)
        XCTAssertEqual(
            Darwin.kill(observedProcessID, 0),
            0,
            "The unrelated Darwin process sharing the recorded Windows PID must remain untouched"
        )
    }

    func testSandboxManagedPrefixActivityFollowsTrackedProcessLifetime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayTrackedActivity-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let runner = makeCuratedRuntimeRunner(sandboxEnabled: true)
        await runner.trackDetachedProcess(process, for: prefix)
        let hasActivityWhileRunning = try await runner.hasManagedPrefixActivity(prefix)
        XCTAssertTrue(hasActivityWhileRunning)

        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(process.isRunning)
        let hasActivityAfterExit = try await runner.hasManagedPrefixActivity(prefix)
        XCTAssertFalse(hasActivityAfterExit)
    }

    func testLsofOnlyWineHolderIsNeverSignalledAndOnlyBecomesCleanAfterExitReobservation() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"),
            "Prefix cleanup verification requires lsof on macOS."
        )
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign"),
            "The native Wine process fixture requires codesign on macOS."
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let launcher = try makeWineRunner(
            in: root,
            wineserverScript: "#!/bin/sh\n[ \"${1:-}\" = \"-w\" ] && exit 0\nexit 1\n"
        )
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let holderExecutable = root.appending(path: "StaleRuntime/wine")
        try FileManager.default.createDirectory(
            at: holderExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: holderExecutable)
        try adHocSignExecutable(holderExecutable)
        let holder = Process()
        holder.executableURL = holderExecutable
        holder.arguments = ["60"]
        holder.currentDirectoryURL = prefix
        try holder.run()
        defer {
            if holder.isRunning {
                holder.terminate()
            }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(holder.isRunning)

        let registry = ManagedWineSessionRegistry()
        registry.record(prefix)
        let runner = makeCuratedRuntimeRunner(
            managedWineSessionRegistry: registry
        )
        let result = try await runner.run(.shutdownWinePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let stderr = try String(contentsOf: result.stderrLog, encoding: .utf8)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(holder.isRunning)
        XCTAssertTrue(
            stderr.contains("Could not verify Wine prefix process cleanup"),
            stderr
        )
        XCTAssertTrue(
            registry.prefixURLs.contains(prefix.standardizedFileURL),
            "failed verification must preserve prefix ownership"
        )

        holder.terminate()
        let exitDeadline = Date().addingTimeInterval(2)
        while holder.isRunning && Date() < exitDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(holder.isRunning)

        let reobserved = try await runner.run(.shutdownWinePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let reobservedStderr = try String(contentsOf: reobserved.stderrLog, encoding: .utf8)
        XCTAssertTrue(
            reobserved.succeeded,
            reobservedStderr
        )
        XCTAssertFalse(
            registry.prefixURLs.contains(prefix.standardizedFileURL),
            "ownership may clear only after a later clean re-observation"
        )
    }

    func testShutdownWinePrefixKillsTrackedDetachedProcessWithoutOpenPrefixFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerEnvironmentCleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let launcher = try makeWineRunner(
            in: root,
            wineserverScript: "#!/bin/sh\n[ \"${1:-}\" = \"-w\" ] && exit 0\nexit 1\n"
        )
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let managedProcess = Process()
        // This boundary verifies cleanup of an explicitly retained Foundation
        // process that has no open prefix file. Use a stable native executable
        // so the fixture does not introduce a shebang-interpreter identity
        // transition that the production curated-runtime path handles through
        // its descriptor-bound tracker.
        managedProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        managedProcess.arguments = ["60"]
        managedProcess.currentDirectoryURL = root
        managedProcess.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "WINEPREFIX": prefix.path
        ]
        try managedProcess.run()
        defer {
            if managedProcess.isRunning {
                managedProcess.terminate()
            }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(managedProcess.isRunning)
        let runner = makeCuratedRuntimeRunner(sandboxEnabled: true)
        await runner.trackDetachedProcess(managedProcess, for: prefix)

        let result = try await runner.run(.shutdownWinePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let stderr = try String(
            contentsOf: result.stderrLog,
            encoding: .utf8
        )

        XCTAssertTrue(result.succeeded, stderr)
        XCTAssertFalse(managedProcess.isRunning, stderr)
    }

    func testShutdownWinePrefixDoesNotKillManagedProcessUsingSiblingPrefixPath() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"),
            "Prefix cleanup verification requires lsof on macOS."
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerSiblingPrefix-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let siblingPrefix = root.appending(path: "Prefix-Other", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let launcher = try makeWineRunner(in: root, wineserverScript: "#!/bin/sh\nexit 0\n")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingPrefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let managedExecutable = root.appending(path: "SiblingRuntime/wine")
        try FileManager.default.createDirectory(
            at: managedExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try managedProcessFixtureScript.write(
            to: managedExecutable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedExecutable.path)
        let siblingProcess = Process()
        siblingProcess.executableURL = managedExecutable
        siblingProcess.arguments = ["60"]
        siblingProcess.currentDirectoryURL = root
        siblingProcess.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "WINEPREFIX": siblingPrefix.path
        ]
        try siblingProcess.run()
        defer {
            if siblingProcess.isRunning {
                siblingProcess.terminate()
            }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(siblingProcess.isRunning)
        let runner = makeCuratedRuntimeRunner()
        await runner.trackDetachedProcess(siblingProcess, for: siblingPrefix)

        let result = try await runner.run(.shutdownWinePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let stderr = try String(contentsOf: result.stderrLog, encoding: .utf8)

        XCTAssertTrue(result.succeeded, stderr)
        XCTAssertTrue(siblingProcess.isRunning, stderr)
    }

    func testUnrelatedLivePrefixHolderIsNotKilledAndObstructsCleanResult() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"),
            "Prefix cleanup verification requires lsof on macOS."
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let launcher = try makeWineRunner(in: root, wineserverScript: "#!/bin/sh\nexit 0\n")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let unrelatedHolder = Process()
        unrelatedHolder.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelatedHolder.arguments = ["60"]
        unrelatedHolder.currentDirectoryURL = prefix
        try unrelatedHolder.run()
        defer {
            if unrelatedHolder.isRunning {
                unrelatedHolder.terminate()
            }
        }
        try await Task.sleep(nanoseconds: 250_000_000)

        let result = try await makeCuratedRuntimeRunner().run(.shutdownWinePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(unrelatedHolder.isRunning)
    }

    func testMisleadingUntrustedHolderIsNotKilledAndObstructsCleanResult() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"),
            "Prefix cleanup verification requires lsof on macOS."
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerArgumentOwnership-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let misleadingFile = prefix.appending(path: "cache/steam.exe")
        let launcher = try makeWineRunner(in: root, wineserverScript: "#!/bin/sh\nexit 0\n")
        try FileManager.default.createDirectory(
            at: misleadingFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "not a managed executable".write(to: misleadingFile, atomically: true, encoding: .utf8)

        let unrelatedHolder = Process()
        unrelatedHolder.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        unrelatedHolder.arguments = ["-f", misleadingFile.path]
        try unrelatedHolder.run()
        defer {
            if unrelatedHolder.isRunning {
                unrelatedHolder.terminate()
            }
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(unrelatedHolder.isRunning)

        let result = try await makeCuratedRuntimeRunner().run(.shutdownWinePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(unrelatedHolder.isRunning)
    }

    func testOpenLogFileHandleRejectsSymlinkLogFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLog = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalRunnerLog-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalLog)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "external log must remain".write(to: externalLog, atomically: true, encoding: .utf8)
        let linkedLog = root.appending(path: "stdout.log")
        try FileManager.default.createSymbolicLink(at: linkedLog, withDestinationURL: externalLog)

        XCTAssertThrowsError(try SafeProcessRunner.openLogFileHandle(at: linkedLog)) { error in
            guard case SafeProcessRunnerError.cannotCreateLog(let url) = error else {
                return XCTFail("Expected cannotCreateLog, got \(error)")
            }
            XCTAssertEqual(url.path, linkedLog.path)
        }
        XCTAssertEqual(try String(contentsOf: externalLog, encoding: .utf8), "external log must remain")
    }

    func testOpenLogFileHandleRejectsHardlinkedLogFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appending(path: "original.log")
        let linked = root.appending(path: "stdout.log")
        try "hardlink target must remain".write(to: original, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: original, to: linked)

        XCTAssertThrowsError(try SafeProcessRunner.openLogFileHandle(at: linked)) { error in
            guard case SafeProcessRunnerError.cannotCreateLog(let url) = error else {
                return XCTFail("Expected cannotCreateLog, got \(error)")
            }
            XCTAssertEqual(url.path, linked.path)
        }
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "hardlink target must remain")
    }

    func testRepeatedRunnerActionsUseDistinctLogFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "wine")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let first = try await makeCuratedRuntimeRunner().run(.probeRuntime(
            executable: launcher,
            logDirectory: logs
        ))
        let second = try await makeCuratedRuntimeRunner().run(.probeRuntime(
            executable: launcher,
            logDirectory: logs
        ))

        XCTAssertNotEqual(first.stdoutLog.path, second.stdoutLog.path)
        XCTAssertNotEqual(first.stderrLog.path, second.stderrLog.path)
    }

    func testSupportArchiveRejectsSymlinkSourceDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayArchiveTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalSource = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalArchiveSource-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalSource)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalSource, withIntermediateDirectories: true)
        let linkedSource = root.appending(path: "Source", directoryHint: .isDirectory)
        let destination = root.appending(path: "bundle.zip")
        try FileManager.default.createSymbolicLink(at: linkedSource, withDestinationURL: externalSource)

        XCTAssertThrowsError(try SafeProcessRunner.validateSupportArchivePaths(
            sourceDirectory: linkedSource,
            destinationZip: destination
        )) { error in
            guard case SafeProcessRunnerError.unsafeArchivePath(let url) = error else {
                return XCTFail("Expected unsafeArchivePath, got \(error)")
            }
            XCTAssertEqual(url.path, linkedSource.path)
        }
    }

    func testSupportArchiveRejectsExistingSymlinkDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayArchiveTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalZip = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalArchive-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalZip)
        }

        let source = root.appending(path: "Source", directoryHint: .isDirectory)
        let destination = root.appending(path: "bundle.zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "external archive".write(to: externalZip, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: externalZip)

        XCTAssertThrowsError(try SafeProcessRunner.validateSupportArchivePaths(
            sourceDirectory: source,
            destinationZip: destination
        )) { error in
            guard case SafeProcessRunnerError.unsafeArchivePath(let url) = error else {
                return XCTFail("Expected unsafeArchivePath, got \(error)")
            }
            XCTAssertEqual(url.path, destination.path)
        }
        XCTAssertEqual(try String(contentsOf: externalZip, encoding: .utf8), "external archive")
    }

    func testSupportArchiveRejectsNonZipDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayArchiveTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appending(path: "Source", directoryHint: .isDirectory)
        let destination = root.appending(path: "bundle.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        XCTAssertThrowsError(try SafeProcessRunner.validateSupportArchivePaths(
            sourceDirectory: source,
            destinationZip: destination
        )) { error in
            guard case SafeProcessRunnerError.unsafeArchivePath(let url) = error else {
                return XCTFail("Expected unsafeArchivePath, got \(error)")
            }
            XCTAssertEqual(url.path, destination.path)
        }
    }

    func testProcessEnvironmentDropsSecretAndInjectionProneParentVariables() {
        let environment = SafeProcessRunner.processEnvironment(
            overrides: [
                "WINEPREFIX": "/tmp/ForgePlayPrefix",
                "WINEARCH": "win64"
            ],
            inherited: [
                "PATH": "/tmp/unsafe-bin:/usr/bin",
                "HOME": "/Users/tester",
                "LANG": "ko_KR.UTF-8",
                "LC_ALL": "ko_KR.UTF-8",
                "API_KEY": "parent-api-secret",
                "TOKEN": "parent-token-secret",
                "FORGEPLAY_SECRET": "parent-forgeplay-secret",
                "DYLD_LIBRARY_PATH": "/tmp/injected-dylib",
                "SSH_AUTH_SOCK": "/tmp/ssh-agent.sock"
            ]
        )

        XCTAssertEqual(environment["WINEPREFIX"], "/tmp/ForgePlayPrefix")
        XCTAssertEqual(environment["WINEARCH"], "win64")
        XCTAssertEqual(environment["HOME"], "/Users/tester")
        XCTAssertEqual(environment["LANG"], "ko_KR.UTF-8")
        XCTAssertEqual(environment["LC_ALL"], "ko_KR.UTF-8")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertNil(environment["API_KEY"])
        XCTAssertNil(environment["TOKEN"])
        XCTAssertNil(environment["FORGEPLAY_SECRET"])
        XCTAssertNil(environment["DYLD_LIBRARY_PATH"])
        XCTAssertNil(environment["SSH_AUTH_SOCK"])
    }

    func testBoundedProcessCaptureDrainsLargeOutputWithoutPipeDeadlock() throws {
        let seq = URL(fileURLWithPath: "/usr/bin/seq")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: seq.path),
            "Large-output process capture requires seq on macOS."
        )

        let capture = try BoundedProcessExecutor.capture(
            executable: seq,
            arguments: ["1", "100000"],
            timeout: 5
        )

        XCTAssertTrue(capture.didExit)
        XCTAssertFalse(capture.didTimeOut)
        XCTAssertEqual(capture.exitCode, 0)
        XCTAssertGreaterThan(capture.stdout.count, 64 * 1024)
        XCTAssertTrue(String(decoding: capture.stdout.suffix(16), as: UTF8.self).contains("100000"))
        XCTAssertTrue(capture.stderr.isEmpty)
    }

    func testBoundedProcessCaptureKillsTermIgnoringProcessAtDeadline() throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        let startedAt = Date()

        let capture = try BoundedProcessExecutor.capture(
            executable: shell,
            arguments: ["-c", "trap '' TERM; exec /bin/sleep 60"],
            timeout: 0.1
        )

        XCTAssertTrue(capture.didExit)
        XCTAssertTrue(capture.didTimeOut)
        XCTAssertNotEqual(capture.exitCode, 0)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
    }

    func testBoundedProcessCancellationTerminatesOnlyOwnedProcessGroup() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayBoundedCancellation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let childPIDURL = root.appending(path: "child.pid")
        let scope = BoundedProcessCancellationScope()
        let operationIdentifier = scope.beginOperation()
        defer { scope.endOperation(operationIdentifier) }
        let startedAt = Date()
        let captureTask = Task.detached {
            try BoundedProcessExecutor.capture(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "trap '' TERM; /bin/sleep 60 & child=$!; " +
                        "printf '%s\\n' \"$child\" > \"$PID_FILE\"; " +
                        "wait \"$child\""
                ],
                environment: [
                    "PATH": "/usr/bin:/bin",
                    "PID_FILE": childPIDURL.path
                ],
                timeout: 60,
                cancellationScope: scope
            )
        }
        let readyDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: childPIDURL.path),
              Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let fixtureWasReady = FileManager.default.fileExists(
            atPath: childPIDURL.path
        )
        XCTAssertTrue(scope.requestCancellation())
        let capture = try await captureTask.value
        XCTAssertTrue(fixtureWasReady)
        guard fixtureWasReady else { return }
        let childPID = try XCTUnwrap(
            Int32(
                String(
                    contentsOf: childPIDURL,
                    encoding: .utf8
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )

        XCTAssertTrue(capture.wasCancelled)
        XCTAssertTrue(capture.didExit)
        XCTAssertFalse(capture.didTimeOut)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
        XCTAssertEqual(Darwin.kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testBoundedProcessCaptureTerminatesSpawnedChildProcesses() throws {
        let capture = try BoundedProcessExecutor.capture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "trap '' TERM; /bin/sleep 60 & child=$!; printf '%s\\n' \"$child\"; wait \"$child\""
            ],
            timeout: 0.2
        )
        let childPIDText = String(decoding: capture.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(Int32(childPIDText))

        XCTAssertTrue(capture.didExit)
        XCTAssertTrue(capture.didTimeOut)
        XCTAssertEqual(Darwin.kill(childPID, 0), -1, "Timed-out helper child process is still alive")
        XCTAssertEqual(errno, ESRCH)
    }

    func testBoundedProcessCaptureTerminatesChildReparentedBeforeFirstPoll() throws {
        let capture = try BoundedProcessExecutor.capture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "/bin/sleep 60 & child=$!; printf '%s\\n' \"$child\"; exit 0"
            ],
            timeout: 2
        )
        let childPIDText = String(decoding: capture.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(Int32(childPIDText))

        XCTAssertTrue(capture.didExit)
        XCTAssertFalse(capture.didTimeOut)
        XCTAssertEqual(capture.exitCode, 0)
        XCTAssertEqual(Darwin.kill(childPID, 0), -1, "Reparented helper child process is still alive")
        XCTAssertEqual(errno, ESRCH)
    }

    func testRunnerEnvironmentAppliesD3DMetalGraphicsBackendOverride() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayD3DMetalEnvironment-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let executable = root.appending(path: "wine")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data().write(to: executable)

        let environment = try SafeProcessRunner.runnerEnvironment(
            for: executable,
            base: ["WINEPREFIX": prefix.path],
            graphicsBackend: .d3dMetal
        )

        XCTAssertEqual(environment["WINEPREFIX"], prefix.path)
        XCTAssertEqual(
            environment["WINEDLLOVERRIDES"],
            "d3d8,d3d9,d3d10,d3d10_1,d3d10core,d3d11,dxgi,d3d12,d3d12core=n,b;winemetal=n,b"
        )
        XCTAssertFalse(environment["WINEDLLOVERRIDES"]?.contains("nvapi") == true)
        XCTAssertFalse(environment["WINEDLLOVERRIDES"]?.contains("nvngx") == true)
        XCTAssertNil(environment["D3DM_ENABLE_METALFX"])
        XCTAssertNil(environment["D3DM_NVNGX_PATH"])
        XCTAssertNil(environment["D3DM_VENDOR_ID"])
        XCTAssertNil(environment["FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP"])
        XCTAssertEqual(environment["VK_ICD_FILENAMES"], "/dev/null")
        XCTAssertEqual(environment["VK_DRIVER_FILES"], "/dev/null")
    }

    func testRunnerEnvironmentAppliesVulkanGraphicsBackendOverride() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayVulkanEnvironment-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let executable = root.appending(path: "wine")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data().write(to: executable)

        let environment = try SafeProcessRunner.runnerEnvironment(
            for: executable,
            base: ["WINEPREFIX": prefix.path],
            graphicsBackend: .vulkan
        )

        XCTAssertEqual(environment["WINEPREFIX"], prefix.path)
        XCTAssertEqual(
            environment["WINEDLLOVERRIDES"],
            "d3d8,d3d9,d3d10,d3d10_1,d3d10core,d3d11,dxgi,d3d12,d3d12core=n,b"
        )
    }

    func testLaunchSteamRejectsMissingManualRendererBeforeStartingWindowsSteam() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "wine")
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let steamExecutable = steamDirectory.appending(path: "steam.exe")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let launchMarker = root.appending(path: "launcher-started")
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("steam".utf8).write(to: steamExecutable)
        try """
        #!/bin/sh
        printf 'started\\n' > "\(launchMarker.path)"
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        do {
            _ = try await makeCuratedRuntimeRunner().run(.launchSteam(
                runtimeExecutable: launcher,
                prefix: prefix,
                steamExecutable: steamExecutable,
                steamArguments: [],
                graphicsBackend: nil,
                logDirectory: logs
            ))
            XCTFail("Expected a missing manual renderer selection to reject Steam launch")
        } catch let evidenceError as ProcessExecutionEvidenceError {
            guard case SafeProcessRunnerError.manualRendererSelectionRequired =
                    evidenceError.underlyingError else {
                return XCTFail("Unexpected underlying error: \(evidenceError.underlyingError)")
            }
            XCTAssertEqual(evidenceError.result.outcome, .preflightFailed)
            XCTAssertFalse(evidenceError.result.hasProcessExitCode)
        } catch SafeProcessRunnerError.manualRendererSelectionRequired {
            // A caller without a writable diagnostic directory still receives
            // the same fail-closed renderer selection error.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: launchMarker.path))
    }

    func testLaunchSteamRejectsExternalGrantFailureBeforeSpawn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlayGrantFailClosed-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "ForgePlayRuntime/wine/bin/wine")
        let prefix = root.appending(path: "Prefixes/SteamShared", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        let steamExecutable = steamDirectory.appending(path: "steam.exe")
        let externalRoot = root.appending(
            path: "ExternalLibrary",
            directoryHint: .isDirectory
        )
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: steamDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("steam".utf8).write(to: steamExecutable)
        try makeCompleteD3DMetalRenderer(
            at: root.appending(
                path: "ForgePlayRuntime/Frameworks/renderer/d3dmetal",
                directoryHint: .isDirectory
            )
        )
        try """
        #!/bin/sh
        printf 'launched=1\\n'
        printf 'grant_file=%s\\n' "$FORGEPLAY_EXTERNAL_STORAGE_GRANT_FILE"
        printf 'grant_sha=%s\\n' "$FORGEPLAY_EXTERNAL_STORAGE_GRANT_SHA256"
        printf 'grant_run=%s\\n' "$FORGEPLAY_EXTERNAL_STORAGE_GRANT_RUN_ID"
        printf 'grant_bridge=%s\\n' "$FORGEPLAY_EXTERNAL_STORAGE_BRIDGE"
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )

        let sensitiveFailureText =
            "bookmark failed at /Volumes/Private Game Library"
        let runner = makeCuratedRuntimeRunner(
            sandboxEnabled: true,
            externalStorageGrantPublisher: { _, _, _ in
                throw NSError(
                    domain: "SafeProcessRunnerTests.ExternalGrant",
                    code: 91,
                    userInfo: [
                        NSLocalizedDescriptionKey: sensitiveFailureText
                    ]
                )
            }
        )
        do {
            _ = try await runner.run(.launchSteam(
                runtimeExecutable: launcher,
                prefix: prefix,
                steamExecutable: steamExecutable,
                steamArguments: [],
                graphicsBackend: .d3dMetal,
                logDirectory: logs,
                externalStorageRoots: [externalRoot]
            ))
            XCTFail(
                "Steam must not launch with a registered external library when its process grant cannot be published"
            )
        } catch let evidenceError as ProcessExecutionEvidenceError {
            let preparationError = try XCTUnwrap(
                evidenceError.underlyingError as?
                    SteamExternalStorageGrantPreparationError
            )
            XCTAssertEqual(preparationError.reasonCode, "publisher-error")
            XCTAssertFalse(preparationError.requiredForManagedChild)
            XCTAssertEqual(evidenceError.result.outcome, .preflightFailed)
            XCTAssertNil(evidenceError.result.processIdentifier)
            XCTAssertFalse(evidenceError.result.hasProcessExitCode)

            let evidenceURL = try XCTUnwrap(evidenceError.result.runEvidenceLog)
            let evidence = try ProcessRunEvidenceWriter.read(from: evidenceURL)
            XCTAssertEqual(
                evidence.runtimeCompatibility?[
                    "externalStorageGrantPublicationStatus"
                ],
                "failed"
            )
            XCTAssertEqual(
                evidence.runtimeCompatibility?[
                    "externalStorageGrantPublicationFailureReason"
                ],
                "publisher-error"
            )
            XCTAssertEqual(
                evidence.runtimeCompatibility?[
                    "externalStorageGrantRequiredForLaunch"
                ],
                "true"
            )
            XCTAssertNil(
                evidence.runtimeCompatibility?[
                    "externalStorageGrantRequiredForManagedChild"
                ]
            )
            for key in SteamExternalStorageProcessGrant.environmentKeys {
                XCTAssertNil(evidence.environmentOverrides[key])
            }
            XCTAssertFalse(
                String(data: try Data(contentsOf: evidenceURL), encoding: .utf8)?
                    .contains(sensitiveFailureText) == true
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testManagedChildLaunchRejectsExternalGrantFailureBeforeSpawnWithEvidence() async throws {
        let fixture = try makeManagedChildExternalGrantLaunchFixture(
            label: "GrantFailClosed"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let runner = makeCuratedRuntimeRunner(
            sandboxEnabled: true,
            managedWineProcessJournalEnabled: false,
            externalStorageGrantPublisher: { _, _, _ in
                throw SteamExternalStorageProcessGrantError.bridgeUnavailable(
                    nil
                )
            }
        )

        do {
            _ = try await runner.run(.launchSteam(
                runtimeExecutable: fixture.launcher,
                prefix: fixture.prefix,
                steamExecutable: fixture.steamExecutable,
                steamArguments: [],
                graphicsBackend: .d3dMetal,
                compatibilitySelection: fixture.compatibilitySelection,
                logDirectory: fixture.logs,
                externalStorageRoots: [fixture.externalRoot]
            ))
            XCTFail(
                "A managed child launch must not spawn without its required external-storage grant"
            )
        } catch let evidenceError as ProcessExecutionEvidenceError {
            guard let preparationError = evidenceError.underlyingError as?
                    SteamExternalStorageGrantPreparationError else {
                return XCTFail(
                    "Unexpected underlying error: \(evidenceError.underlyingError)"
                )
            }
            XCTAssertEqual(preparationError.reasonCode, "bridge-unavailable")
            XCTAssertTrue(preparationError.requiredForManagedChild)
            XCTAssertEqual(evidenceError.result.outcome, .preflightFailed)
            XCTAssertFalse(evidenceError.result.hasProcessExitCode)
            XCTAssertFalse(evidenceError.result.waitedForExit)
            XCTAssertNil(evidenceError.result.processIdentifier)

            let evidenceURL = try XCTUnwrap(
                evidenceError.result.runEvidenceLog
            )
            let evidence = try ProcessRunEvidenceWriter.read(
                from: evidenceURL
            )
            XCTAssertEqual(evidence.outcome, .preflightFailed)
            XCTAssertNil(evidence.exitCode)
            XCTAssertNil(evidence.processIdentifier)
            XCTAssertEqual(
                evidence.runtimeCompatibility?[
                    "externalStorageGrantPublicationStatus"
                ],
                "failed"
            )
            XCTAssertEqual(
                evidence.runtimeCompatibility?[
                    "externalStorageGrantPublicationFailureReason"
                ],
                "bridge-unavailable"
            )
            XCTAssertEqual(
                evidence.runtimeCompatibility?[
                    "externalStorageGrantRequiredForLaunch"
                ],
                "true"
            )
            XCTAssertEqual(
                evidence.runtimeCompatibility?[
                    "externalStorageGrantRequiredForManagedChild"
                ],
                "true"
            )
            for key in SteamExternalStorageProcessGrant.environmentKeys {
                XCTAssertNil(evidence.environmentOverrides[key])
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.launchMarker.path)
        )
    }

    func testManagedChildLaunchPublishesRequiredExternalGrant() async throws {
        let fixture = try makeManagedChildExternalGrantLaunchFixture(
            label: "GrantPublished"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manifest = fixture.root.appending(path: "grant.json")
        let bridge = fixture.root.appending(path: "grant-bridge.dylib")
        try Data("{}".utf8).write(to: manifest)
        try Data("bridge".utf8).write(to: bridge)
        let manifestSHA256 = String(repeating: "c", count: 64)

        let runner = makeCuratedRuntimeRunner(
            sandboxEnabled: true,
            managedWineProcessJournalEnabled: false,
            externalStorageGrantPublisher: { _, _, runIdentifier in
                SteamExternalStorageProcessGrant(
                    manifestURL: manifest,
                    manifestSHA256: manifestSHA256,
                    runIdentifier: runIdentifier,
                    bridgeURL: bridge
                )
            }
        )
        let result = try await runner.run(.launchSteam(
            runtimeExecutable: fixture.launcher,
            prefix: fixture.prefix,
            steamExecutable: fixture.steamExecutable,
            steamArguments: [],
            graphicsBackend: .d3dMetal,
            compatibilitySelection: fixture.compatibilitySelection,
            logDirectory: fixture.logs,
            externalStorageRoots: [fixture.externalRoot]
        ))

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.launchMarker.path)
        )
        let output = try String(
            contentsOf: result.stdoutLog,
            encoding: .utf8
        )
        XCTAssertTrue(output.contains("grant_file=\(manifest.path)"), output)
        XCTAssertTrue(output.contains("grant_sha=\(manifestSHA256)"), output)
        XCTAssertTrue(output.contains("grant_run="), output)
        XCTAssertTrue(output.contains("grant_bridge=\(bridge.path)"), output)

        let evidence = try ProcessRunEvidenceWriter.read(
            from: try XCTUnwrap(result.runEvidenceLog)
        )
        XCTAssertEqual(
            evidence.runtimeCompatibility?[
                "externalStorageGrantPublicationStatus"
            ],
            "published"
        )
        XCTAssertEqual(
            evidence.runtimeCompatibility?[
                "externalStorageGrantRequiredForLaunch"
            ],
            "true"
        )
        XCTAssertEqual(
            evidence.runtimeCompatibility?[
                "externalStorageGrantRequiredForManagedChild"
            ],
            "true"
        )
        XCTAssertEqual(
            evidence.runtimeCompatibility?["externalStorageGrantSHA256"],
            manifestSHA256
        )
    }

    func testManagedChildLaunchRejectsMissingExternalGrantRootBeforeSpawn() async throws {
        let fixture = try makeManagedChildExternalGrantLaunchFixture(
            label: "GrantRootMissing"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let runner = makeCuratedRuntimeRunner(
            sandboxEnabled: true,
            managedWineProcessJournalEnabled: false,
            externalStorageGrantPublisher: { _, _, _ in
                XCTFail("A missing required root must fail before publication")
                throw SteamExternalStorageProcessGrantError.externalStorageRootRequired
            }
        )

        do {
            _ = try await runner.run(.launchSteam(
                runtimeExecutable: fixture.launcher,
                prefix: fixture.prefix,
                steamExecutable: fixture.steamExecutable,
                steamArguments: [],
                graphicsBackend: .d3dMetal,
                compatibilitySelection: fixture.compatibilitySelection,
                logDirectory: fixture.logs,
                externalStorageRoots: []
            ))
            XCTFail("A managed child launch must not spawn without its required external-storage root")
        } catch let evidenceError as ProcessExecutionEvidenceError {
            let preparationError = try XCTUnwrap(
                evidenceError.underlyingError as?
                    SteamExternalStorageGrantPreparationError
            )
            XCTAssertEqual(preparationError.reasonCode, "root-required")
            XCTAssertTrue(preparationError.requiredForManagedChild)
            XCTAssertEqual(evidenceError.result.outcome, .preflightFailed)
            let evidence = try ProcessRunEvidenceWriter.read(
                from: try XCTUnwrap(evidenceError.result.runEvidenceLog)
            )
            XCTAssertEqual(
                evidence.runtimeCompatibility?[
                    "externalStorageGrantPublicationFailureReason"
                ],
                "root-required"
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.launchMarker.path)
        )
    }

    func testLaunchSteamUsesForgePlaySteamLauncherWhenRuntimeProvidesIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let wineRoot = root.appending(path: "ForgePlayRuntime/wine", directoryHint: .isDirectory)
        let bin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let windowsDLLs = wineRoot.appending(path: "lib/wine/x86_64-windows", directoryHint: .isDirectory)
        let prefix = root.appending(path: "Prefixes/SteamShared", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let steamExecutable = steamDirectory.appending(path: "steam.exe")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: windowsDLLs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("steam".utf8).write(to: steamExecutable)
        try makeManagedD3DMetalRenderer(for: prefix)

        let launcher = bin.appending(path: "wine")
        let wineLoader = bin.appending(path: "wine.bin")
        let wineserver = bin.appending(path: "wineserver")
        let steamLauncher = windowsDLLs.appending(path: "forgeplay-steam-launcher.exe")
        try """
        #!/bin/sh
        printf 'WINELOADER=%s\\n' "$WINELOADER"
        printf 'FORGEPLAY_STEAM_LAUNCHER=%s\\n' "$FORGEPLAY_STEAM_LAUNCHER"
        printf 'WINESERVER=%s\\n' "$WINESERVER"
        index=0
        for argument in "$@"; do
          printf 'ARG[%s]=%s\\n' "$index" "$argument"
          index=$((index + 1))
        done
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: wineLoader, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: wineserver, atomically: true, encoding: .utf8)
        try Data("forgeplay steam launcher".utf8).write(to: steamLauncher)
        for executable in [launcher, wineLoader, wineserver, steamLauncher] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        let result = try await makeCuratedRuntimeRunner().run(.launchSteam(
            runtimeExecutable: launcher,
            prefix: prefix,
            steamExecutable: steamExecutable,
            steamArguments: ["-no-cef-sandbox"],
            graphicsBackend: .d3dMetal,
            logDirectory: logs
        ))
        let output = try await waitForLogContents(at: result.stdoutLog, containing: "ARG[4]=-no-cef-sandbox")

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.waitedForExit)
        XCTAssertEqual(result.outcome, .exited)
        XCTAssertEqual(
            SteamLaunchDispatchDisposition.resolve(result),
            .successfulForgePlayLauncherHandoff
        )
        XCTAssertEqual(result.executable.standardizedFileURL.path, launcher.standardizedFileURL.path)
        XCTAssertTrue(output.contains("WINELOADER=\(wineLoader.path)"), output)
        XCTAssertTrue(output.contains("FORGEPLAY_STEAM_LAUNCHER=\(steamLauncher.path)"), output)
        XCTAssertTrue(output.contains("WINESERVER=\(wineserver.path)"), output)
        XCTAssertTrue(output.contains("ARG[0]=\(steamLauncher.path)"), output)
        XCTAssertTrue(output.contains("ARG[1]=--detach"), output)
        XCTAssertTrue(output.contains("ARG[2]=--"), output)
        XCTAssertTrue(output.contains("ARG[3]=C:\\Program Files (x86)\\Steam\\steam.exe"), output)
        XCTAssertTrue(output.contains("ARG[4]=-no-cef-sandbox"), output)
    }

    func testLaunchSteamReturnsForgePlaySteamLauncherImmediateFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeEntrypointFailure-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let wineRoot = root.appending(path: "ForgePlayRuntime/wine", directoryHint: .isDirectory)
        let bin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let windowsDLLs = wineRoot.appending(path: "lib/wine/x86_64-windows", directoryHint: .isDirectory)
        let prefix = root.appending(path: "Prefixes/SteamShared", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let steamExecutable = steamDirectory.appending(path: "steam.exe")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: windowsDLLs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("steam".utf8).write(to: steamExecutable)
        try makeManagedD3DMetalRenderer(for: prefix)

        let launcher = bin.appending(path: "wine")
        let wineLoader = bin.appending(path: "wine.bin")
        let wineserver = bin.appending(path: "wineserver")
        let steamLauncher = windowsDLLs.appending(path: "forgeplay-steam-launcher.exe")
        try "#!/bin/sh\nexit 42\n".write(to: launcher, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: wineLoader, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: wineserver, atomically: true, encoding: .utf8)
        try Data("forgeplay steam launcher".utf8).write(to: steamLauncher)
        for executable in [launcher, wineLoader, wineserver, steamLauncher] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        let result = try await makeCuratedRuntimeRunner().run(.launchSteam(
            runtimeExecutable: launcher,
            prefix: prefix,
            steamExecutable: steamExecutable,
            steamArguments: ["-no-cef-sandbox"],
            graphicsBackend: .d3dMetal,
            logDirectory: logs
        ))

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.waitedForExit)
        XCTAssertEqual(result.exitCode, 42)
        XCTAssertEqual(
            SteamLaunchDispatchDisposition.resolve(result),
            .completedOrFailed
        )
    }

    private func waitForLogContents(
        at url: URL,
        containing marker: String,
        timeout: TimeInterval = 2
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = ""
        repeat {
            latest = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if latest.contains(marker) {
                return latest
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        return latest
    }

    func testLaunchSteamD3DMetalKeepsGameRendererOutOfSteamClientEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtimeRoot = root.appending(path: "ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let bin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let icdDirectory = wineRoot.appending(path: "etc/vulkan/icd.d", directoryHint: .isDirectory)
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let steamExecutable = steamDirectory.appending(path: "steam.exe")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let d3dMetalRenderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let d9vkRenderer = runtimeRoot.appending(path: "Frameworks/renderer/d9vk", directoryHint: .isDirectory)
        let dxmtRenderer = runtimeRoot.appending(path: "Frameworks/renderer/dxmt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: icdDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("steam".utf8).write(to: steamExecutable)
        try makeCompleteD3DMetalRenderer(at: d3dMetalRenderer)
        try makeCompleteD9VKRenderer(at: d9vkRenderer)
        try makeCompleteDXMTRenderer(at: dxmtRenderer)
        try #"{"ICD":{"library_path":"../../lib/libMoltenVK.dylib","api_version":"1.4.0"}}"#
            .write(to: icdDirectory.appending(path: "MoltenVK_icd.json"), atomically: true, encoding: .utf8)
        let launcher = bin.appending(path: "wine")
        try """
        #!/bin/sh
        printf 'WINEDLLOVERRIDES=%s\\n' "$WINEDLLOVERRIDES"
        printf 'WINEDLLPATH=%s\\n' "$WINEDLLPATH"
        printf 'D3DMETAL_FRAMEWORK_PATH=%s\\n' "$D3DMETAL_FRAMEWORK_PATH"
        printf 'D3DM_ENABLE_METALFX=%s\\n' "$D3DM_ENABLE_METALFX"
        printf 'D3DM_NVNGX_PATH=%s\\n' "$D3DM_NVNGX_PATH"
        printf 'D3DM_VENDOR_ID=%s\\n' "$D3DM_VENDOR_ID"
        printf 'FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP=%s\\n' "$FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP"
        printf 'VK_ICD_FILENAMES=%s\\n' "$VK_ICD_FILENAMES"
        printf 'FORGEPLAY_PROCESS_OBSERVATION_TARGET=%s\\n' "$FORGEPLAY_PROCESS_OBSERVATION_TARGET"
        printf 'FORGEPLAY_PROCESS_ARGUMENT_TARGET=%s\\n' "$FORGEPLAY_PROCESS_ARGUMENT_TARGET"
        printf 'FORGEPLAY_PROCESS_ARGUMENT_APPEND=%s\\n' "$FORGEPLAY_PROCESS_ARGUMENT_APPEND"
        printf 'FORGEPLAY_PROCESS_ARGUMENT_ROOT_ONLY=%s\\n' "$FORGEPLAY_PROCESS_ARGUMENT_ROOT_ONLY"
        printf 'FORGEPLAY_STEAM_GAME_CEF_BROWSER_POLICY_ENABLED=%s\\n' "$FORGEPLAY_STEAM_GAME_CEF_BROWSER_POLICY_ENABLED"
        printf 'FORGEPLAY_GAME_RENDERER_POLICY_ENABLED=%s\\n' "$FORGEPLAY_GAME_RENDERER_POLICY_ENABLED"
        printf 'FORGEPLAY_GAME_RENDERER_POLICY=%s\\n' "$FORGEPLAY_GAME_RENDERER_POLICY"
        printf 'FORGEPLAY_GAME_RENDERER_REQUESTED=%s\\n' "$FORGEPLAY_GAME_RENDERER_REQUESTED"
        printf 'FORGEPLAY_GAME_RENDERER_COMPONENTS_X64=%s\\n' "$FORGEPLAY_GAME_RENDERER_COMPONENTS_X64"
        printf 'FORGEPLAY_GAME_RENDERER_COMPONENTS_X86=%s\\n' "$FORGEPLAY_GAME_RENDERER_COMPONENTS_X86"
        printf 'FORGEPLAY_GAME_RENDERER_DLL_PATH_X64=%s\\n' "$FORGEPLAY_GAME_RENDERER_DLL_PATH_X64"
        printf 'FORGEPLAY_GAME_RENDERER_DLL_PATH_X86=%s\\n' "$FORGEPLAY_GAME_RENDERER_DLL_PATH_X86"
        printf 'FORGEPLAY_GAME_RENDERER_ENV_WINEDLLOVERRIDES=%s\\n' "$FORGEPLAY_GAME_RENDERER_ENV_WINEDLLOVERRIDES"
        printf 'FORGEPLAY_GAME_RENDERER_ENV_D3DMETAL_FRAMEWORK_PATH=%s\\n' "$FORGEPLAY_GAME_RENDERER_ENV_D3DMETAL_FRAMEWORK_PATH"
        printf 'FORGEPLAY_GAME_RENDERER_ENV_D3DM_WINE_UNIX_CALL=%s\\n' "$FORGEPLAY_GAME_RENDERER_ENV_D3DM_WINE_UNIX_CALL"
        printf 'FORGEPLAY_GAME_RENDERER_ENV_D3DM_ENABLE_METALFX=%s\\n' "$FORGEPLAY_GAME_RENDERER_ENV_D3DM_ENABLE_METALFX"
        printf 'FORGEPLAY_GAME_RENDERER_ENV_D3DM_NVNGX_PATH=%s\\n' "$FORGEPLAY_GAME_RENDERER_ENV_D3DM_NVNGX_PATH"
        printf 'FORGEPLAY_GAME_RENDERER_ENV_D3DM_VENDOR_ID=%s\\n' "$FORGEPLAY_GAME_RENDERER_ENV_D3DM_VENDOR_ID"
        printf 'FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP=%s\\n' "$FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP"
        printf 'FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NETWORK_PROFILE=%s\\n' "$FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NETWORK_PROFILE"
        printf 'FORGEPLAY_GAME_RENDERER_BASE_ENV_D3DM_ENABLE_METALFX=%s\\n' "$FORGEPLAY_GAME_RENDERER_BASE_ENV_D3DM_ENABLE_METALFX"
        printf 'FORGEPLAY_GAME_RENDERER_BASE_ENV_D3DM_NVNGX_PATH=%s\\n' "$FORGEPLAY_GAME_RENDERER_BASE_ENV_D3DM_NVNGX_PATH"
        printf 'FORGEPLAY_GAME_RENDERER_BASE_ENV_D3DM_VENDOR_ID=%s\\n' "$FORGEPLAY_GAME_RENDERER_BASE_ENV_D3DM_VENDOR_ID"
        printf 'FORGEPLAY_GAME_RENDERER_BASE_ENV_FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP=%s\\n' "$FORGEPLAY_GAME_RENDERER_BASE_ENV_FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP"
        printf 'FORGEPLAY_GAME_RENDERER_BASE_ENV_FORGEPLAY_NETWORK_PROFILE=%s\\n' "$FORGEPLAY_GAME_RENDERER_BASE_ENV_FORGEPLAY_NETWORK_PROFILE"
        printf 'FORGEPLAY_GAME_RENDERER_BASE_HELPER_SUFFIX_RULES_V1=%s\\n' "$FORGEPLAY_GAME_RENDERER_BASE_HELPER_SUFFIX_RULES_V1"
        printf 'FORGEPLAY_NETWORK_PROFILE=%s\\n' "$FORGEPLAY_NETWORK_PROFILE"
        printf 'FORGEPLAY_NETWORK_PROFILE_REQUESTED=%s\\n' "$FORGEPLAY_NETWORK_PROFILE_REQUESTED"
        printf 'FORGEPLAY_AUDIO_INPUT_MODE=%s\\n' "$FORGEPLAY_AUDIO_INPUT_MODE"
        printf 'SL_ENABLE_CONSOLE_LOGGING=%s\\n' "$SL_ENABLE_CONSOLE_LOGGING"
        printf 'SL_LOG_LEVEL=%s\\n' "$SL_LOG_LEVEL"
        printf 'SL_LOG_PATH=%s\\n' "$SL_LOG_PATH"
        printf 'SL_LOG_NAME=%s\\n' "$SL_LOG_NAME"
        printf 'AUTOMATIC_PROFILES=%s\\n' "$FORGEPLAY_GAME_RENDERER_AVAILABLE_PROFILES"
        printf 'LOADER_X64=%s\\n' "$FORGEPLAY_GAME_RENDERER_PROFILE_LOADER_X64_COMPONENTS_X64"
        printf 'LOADER_X86=%s\\n' "$FORGEPLAY_GAME_RENDERER_PROFILE_LOADER_X86_COMPONENTS_X86"
        printf '%s\\n' "$@"
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try installManagedWineLoaderFixture(for: launcher)

        let result = try await makeCuratedRuntimeRunner().run(.launchSteam(
            runtimeExecutable: launcher,
            prefix: prefix,
            steamExecutable: steamExecutable,
            steamArguments: [],
            graphicsBackend: .d3dMetal,
            compatibilitySelection: SteamPrelaunchCompatibilitySelection(
                rendererSelection: .d3dMetalNVIDIA,
                networkSelection: .wifiIdentity,
                audioInputSelection: .disabled
            ),
            logDirectory: logs
        ))
        let output = try String(contentsOf: result.stdoutLog, encoding: .utf8)
        let outputLines = output.split(whereSeparator: \.isNewline).map(String.init)

        XCTAssertTrue(result.succeeded)
        let steamDLLOverrides = try XCTUnwrap(outputLines.first { $0.hasPrefix("WINEDLLOVERRIDES=") })
        XCTAssertFalse(steamDLLOverrides.contains("d3d11,dxgi"), output)
        XCTAssertFalse(steamDLLOverrides.contains("winemetal"), output)
        let steamWineDLLPath = try XCTUnwrap(outputLines.first { $0.hasPrefix("WINEDLLPATH=") })
        XCTAssertFalse(steamWineDLLPath.contains("renderer/d3dmetal"), output)
        XCTAssertFalse(steamWineDLLPath.contains("renderer/d9vk"), output)
        XCTAssertFalse(steamWineDLLPath.contains("renderer/dxmt"), output)
        XCTAssertTrue(outputLines.contains("D3DMETAL_FRAMEWORK_PATH="), output)
        XCTAssertTrue(outputLines.contains("D3DM_ENABLE_METALFX="), output)
        XCTAssertTrue(outputLines.contains("D3DM_NVNGX_PATH="), output)
        XCTAssertTrue(outputLines.contains("D3DM_VENDOR_ID="), output)
        XCTAssertTrue(
            outputLines.contains("FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP="),
            output
        )
        XCTAssertTrue(output.contains("VK_ICD_FILENAMES="), output)
        XCTAssertFalse(outputLines.contains("VK_ICD_FILENAMES=/dev/null"), output)
        XCTAssertTrue(output.contains("wine/etc/vulkan/icd.d/MoltenVK_icd.json"), output)
        XCTAssertTrue(
            outputLines.contains(
                "FORGEPLAY_PROCESS_OBSERVATION_TARGET=steamwebhelper.exe"
            ),
            output
        )
        XCTAssertTrue(
            outputLines.contains(
                "FORGEPLAY_PROCESS_ARGUMENT_TARGET=steamwebhelper.exe"
            ),
            output
        )
        XCTAssertTrue(
            outputLines.contains(
                "FORGEPLAY_PROCESS_ARGUMENT_APPEND=--no-sandbox --in-process-gpu --disable-gpu"
            ),
            output
        )
        XCTAssertTrue(
            outputLines.contains("FORGEPLAY_PROCESS_ARGUMENT_ROOT_ONLY=1"),
            output
        )
        XCTAssertTrue(
            outputLines.contains("FORGEPLAY_STEAM_GAME_CEF_BROWSER_POLICY_ENABLED=1"),
            output
        )
        XCTAssertTrue(outputLines.contains("FORGEPLAY_GAME_RENDERER_POLICY_ENABLED=1"), output)
        XCTAssertTrue(outputLines.contains("FORGEPLAY_GAME_RENDERER_POLICY=d3dMetal"), output)
        XCTAssertTrue(
            outputLines.contains("FORGEPLAY_GAME_RENDERER_REQUESTED=d3dMetalNVIDIA"),
            output
        )
        XCTAssertTrue(outputLines.contains("FORGEPLAY_GAME_RENDERER_COMPONENTS_X64=d3dmetal"), output)
        XCTAssertTrue(outputLines.contains("FORGEPLAY_GAME_RENDERER_COMPONENTS_X86="), output)
        XCTAssertTrue(output.contains("FORGEPLAY_GAME_RENDERER_DLL_PATH_X64=Z:"), output)
        XCTAssertTrue(output.contains("wine\\x86_64-windows"), output)
        XCTAssertTrue(outputLines.contains("FORGEPLAY_GAME_RENDERER_DLL_PATH_X86="), output)
        XCTAssertTrue(output.contains("FORGEPLAY_GAME_RENDERER_ENV_WINEDLLOVERRIDES="), output)
        XCTAssertTrue(output.contains("d3d11"), output)
        XCTAssertTrue(output.contains("d3d12"), output)
        XCTAssertFalse(output.contains("/renderer/d9vk/"), output)
        XCTAssertFalse(output.contains("/renderer/dxmt/"), output)
        XCTAssertFalse(output.contains("/renderer/dxvk/"), output)
        XCTAssertTrue(output.contains("FORGEPLAY_GAME_RENDERER_ENV_D3DMETAL_FRAMEWORK_PATH="), output)
        XCTAssertTrue(output.contains("D3DMetal.framework"), output)
        XCTAssertTrue(outputLines.contains("FORGEPLAY_GAME_RENDERER_ENV_D3DM_WINE_UNIX_CALL=1"), output)
        XCTAssertTrue(
            outputLines.contains("FORGEPLAY_GAME_RENDERER_ENV_D3DM_ENABLE_METALFX=1"),
            output
        )
        XCTAssertTrue(
            outputLines.contains {
                $0.hasPrefix("FORGEPLAY_GAME_RENDERER_ENV_D3DM_NVNGX_PATH=") &&
                    $0.contains("/.forgeplay/renderer-bridges/d3dmetal/")
            },
            output
        )
        XCTAssertTrue(
            outputLines.contains("FORGEPLAY_GAME_RENDERER_ENV_D3DM_VENDOR_ID=0x10de"),
            output
        )
        XCTAssertTrue(
            outputLines.contains(
                "FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP=1"
            ),
            output
        )
        XCTAssertTrue(
            outputLines.contains(
                "FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NETWORK_PROFILE=wifi-identity"
            ),
            output
        )
        XCTAssertTrue(
            outputLines.contains(
                "FORGEPLAY_GAME_RENDERER_BASE_ENV_D3DM_ENABLE_METALFX=__FORGEPLAY_UNSET__"
            ),
            output
        )
        XCTAssertTrue(
            outputLines.contains(
                "FORGEPLAY_GAME_RENDERER_BASE_ENV_D3DM_NVNGX_PATH=__FORGEPLAY_UNSET__"
            ),
            output
        )
        XCTAssertTrue(
            outputLines.contains(
                "FORGEPLAY_GAME_RENDERER_BASE_ENV_D3DM_VENDOR_ID=__FORGEPLAY_UNSET__"
            ),
            output
        )
        XCTAssertTrue(
            outputLines.contains(
                "FORGEPLAY_GAME_RENDERER_BASE_ENV_FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP=__FORGEPLAY_UNSET__"
            ),
            output
        )
        XCTAssertTrue(
            outputLines.contains(
                "FORGEPLAY_GAME_RENDERER_BASE_ENV_FORGEPLAY_NETWORK_PROFILE=__FORGEPLAY_UNSET__"
            ),
            output
        )
        XCTAssertTrue(
            outputLines.contains {
                $0.hasPrefix(
                    "FORGEPLAY_GAME_RENDERER_BASE_HELPER_SUFFIX_RULES_V1="
                ) &&
                    $0.contains(
                        "\\steamapps\\common\\BlueArchive\\BlueArchive_Data\\Plugins\\x86_64\\grap\\NGService.exe"
                    )
            },
            output
        )
        XCTAssertTrue(outputLines.contains("FORGEPLAY_NETWORK_PROFILE="), output)
        XCTAssertTrue(
            outputLines.contains("FORGEPLAY_NETWORK_PROFILE_REQUESTED=wifi-identity"),
            output
        )
        XCTAssertTrue(
            outputLines.contains("FORGEPLAY_AUDIO_INPUT_MODE=disabled"),
            output
        )
        XCTAssertTrue(
            outputLines.contains("SL_ENABLE_CONSOLE_LOGGING=0"),
            output
        )
        XCTAssertTrue(outputLines.contains("SL_LOG_LEVEL=2"), output)
        XCTAssertTrue(
            outputLines.contains {
                $0.hasPrefix("SL_LOG_PATH=Z:") &&
                    $0.contains("\\Logs")
            },
            output
        )
        XCTAssertTrue(
            outputLines.contains(
                "SL_LOG_NAME=forgeplay-streamline.log"
            ),
            output
        )
        XCTAssertTrue(outputLines.contains("AUTOMATIC_PROFILES="), output)
        XCTAssertTrue(outputLines.contains("LOADER_X64="), output)
        XCTAssertTrue(outputLines.contains("LOADER_X86="), output)
    }

    func testD3DMetalBackendUsesOnlyD3DMetalSearchPathsBeforeBaseWineDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtimeRoot = root.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let frameworks = runtimeRoot.appending(path: "Frameworks", directoryHint: .isDirectory)
        let d3dMetalRenderer = frameworks.appending(path: "renderer/d3dmetal", directoryHint: .isDirectory)
        let d9vkRenderer = frameworks.appending(path: "renderer/d9vk", directoryHint: .isDirectory)
        let dxmtRenderer = frameworks.appending(path: "renderer/dxmt", directoryHint: .isDirectory)
        let dxvkRenderer = frameworks.appending(path: "renderer/dxvk", directoryHint: .isDirectory)
        let dxmtWine = frameworks.appending(path: "renderer/dxmt/wine", directoryHint: .isDirectory)
        let dxmtUnix = dxmtWine.appending(path: "x86_64-unix", directoryHint: .isDirectory)
        let dxmtX64Windows = dxmtWine.appending(path: "x86_64-windows", directoryHint: .isDirectory)
        let d3dMetalWine = d3dMetalRenderer.appending(path: "wine", directoryHint: .isDirectory)
        let d3dMetalUnix = d3dMetalWine.appending(path: "x86_64-unix", directoryHint: .isDirectory)
        let d3dMetalX64Windows = d3dMetalWine.appending(path: "x86_64-windows", directoryHint: .isDirectory)
        let d9vkWine = d9vkRenderer.appending(path: "wine", directoryHint: .isDirectory)
        let dxvkWine = frameworks.appending(path: "renderer/dxvk/wine", directoryHint: .isDirectory)
        let dxvkUnix = dxvkWine.appending(path: "x86_64-unix", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let runtimeLibraryDirectory = wineRoot.appending(path: "lib", directoryHint: .isDirectory)
        let bin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let libWine = wineRoot.appending(path: "lib/wine", directoryHint: .isDirectory)
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        try makeCompleteD3DMetalRenderer(at: d3dMetalRenderer)
        try makeCompleteD9VKRenderer(at: d9vkRenderer)
        try makeCompleteDXMTRenderer(at: dxmtRenderer)
        try makeCompleteDXVKRenderer(at: dxvkRenderer)
        try FileManager.default.createDirectory(at: dxvkUnix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libWine, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>DXMT</key>
            <integer>1</integer>
            <key>D3DMETAL</key>
            <integer>0</integer>
            <key>DXVK</key>
            <integer>0</integer>
            <key>D9VK</key>
            <integer>0</integer>
        </dict>
        </plist>
        """.write(to: runtimeRoot.appending(path: "Info.plist"), atomically: true, encoding: .utf8)

        let launcher = bin.appending(path: "wine")
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let environment = try SafeProcessRunner.runnerEnvironment(
            for: launcher,
            base: ["WINEPREFIX": prefix.path],
            graphicsBackend: .d3dMetal
        )
        let wineDLLPath = environment["WINEDLLPATH"]?.split(separator: ":").map(String.init)
        let resolvedWineDLLPaths = wineDLLPath?.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        } ?? []
        let resolvedDynamicLibraryPaths = environment["DYLD_LIBRARY_PATH"]?
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).resolvingSymlinksInPath().path } ?? []
        let resolvedFallbackLibraryPaths = environment["DYLD_FALLBACK_LIBRARY_PATH"]?
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).resolvingSymlinksInPath().path } ?? []
        let leadingWineDLLPaths = wineDLLPath.map { Array($0.prefix(3)) } ?? []
        let resolvedLeadingWineDLLPaths = leadingWineDLLPaths.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        let expectedLeadingWineDLLPaths = [
            d3dMetalWine,
            d3dMetalUnix,
            d3dMetalX64Windows
        ].map {
            $0.resolvingSymlinksInPath().path
        }

        XCTAssertEqual(
            resolvedLeadingWineDLLPaths,
            expectedLeadingWineDLLPaths,
            "WINEDLLPATH=\(wineDLLPath ?? [])"
        )
        XCTAssertFalse(resolvedWineDLLPaths.contains(d9vkWine.resolvingSymlinksInPath().path))
        XCTAssertFalse(resolvedWineDLLPaths.contains(dxvkWine.resolvingSymlinksInPath().path))
        XCTAssertFalse(resolvedWineDLLPaths.contains(dxmtX64Windows.resolvingSymlinksInPath().path))
        XCTAssertFalse(resolvedWineDLLPaths.contains(dxmtWine.resolvingSymlinksInPath().path))
        XCTAssertFalse(resolvedWineDLLPaths.contains(dxmtUnix.resolvingSymlinksInPath().path))
        XCTAssertFalse(
            resolvedDynamicLibraryPaths.contains(frameworks.resolvingSymlinksInPath().path),
            "Top-level Frameworks must not override macOS libiconv in DYLD_LIBRARY_PATH"
        )
        XCTAssertFalse(
            resolvedFallbackLibraryPaths.contains(frameworks.resolvingSymlinksInPath().path),
            "Exact D3DMetal selection must not expose the top-level mixed renderer directory"
        )
        XCTAssertTrue(resolvedDynamicLibraryPaths.contains(d3dMetalUnix.resolvingSymlinksInPath().path))
        XCTAssertFalse(resolvedDynamicLibraryPaths.contains(dxmtUnix.resolvingSymlinksInPath().path))
        XCTAssertFalse(resolvedDynamicLibraryPaths.contains(dxvkUnix.resolvingSymlinksInPath().path))
        XCTAssertTrue(
            resolvedDynamicLibraryPaths.contains(
                runtimeLibraryDirectory.resolvingSymlinksInPath().path
            )
        )
    }

    func testRunnerEnvironmentUsesOnlyBundledGStreamerPlugins() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let wineRoot = root.appending(path: "ForgePlayRuntime/wine", directoryHint: .isDirectory)
        let bin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let wineDLLs = wineRoot.appending(path: "lib/wine", directoryHint: .isDirectory)
        let gstreamerLibrary = wineRoot.appending(
            path: "gstreamer/lib",
            directoryHint: .isDirectory
        )
        let gstreamerPlugins = gstreamerLibrary.appending(
            path: "gstreamer-1.0",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wineDLLs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: gstreamerPlugins,
            withIntermediateDirectories: true
        )

        let launcher = bin.appending(path: "wine")
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )

        let environment = try SafeProcessRunner.runnerEnvironment(
            for: launcher,
            base: [
                "GST_PLUGIN_PATH_1_0": "/tmp/unreviewed-plugins",
                "GST_PLUGIN_SYSTEM_PATH_1_0": "/usr/local/lib/gstreamer-1.0"
            ]
        )

        XCTAssertEqual(environment["GST_PLUGIN_PATH_1_0"], gstreamerPlugins.path)
        XCTAssertEqual(environment["GST_PLUGIN_SYSTEM_PATH_1_0"], "")
        XCTAssertTrue(
            environment["DYLD_LIBRARY_PATH"]?
                .split(separator: ":")
                .map(String.init)
                .contains(gstreamerLibrary.path) == true
        )
        XCTAssertTrue(
            environment["DYLD_FALLBACK_LIBRARY_PATH"]?
                .split(separator: ":")
                .map(String.init)
                .contains(gstreamerLibrary.path) == true
        )
    }

    func testManagedAppleSupplementalRendererIsComposedOnlyForGameLaunch() throws {
        let managedRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayManagedRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: managedRoot) }

        let prefix = managedRoot.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let wineRoot = managedRoot.appending(
            path: "BundledResources/Runners/ForgePlayRuntime/wine",
            directoryHint: .isDirectory
        )
        let bin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let supplementalRenderer = managedRoot.appending(
            path: "Renderers/AppleD3DMetal/SupplementalEvaluationEnvironment/lib",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: wineRoot.appending(path: "lib/wine", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try makeCompleteD3DMetalRenderer(at: supplementalRenderer)

        let launcher = bin.appending(path: "wine")
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let steamEnvironment = try SafeProcessRunner.runnerEnvironment(
            for: launcher,
            base: ["WINEPREFIX": prefix.path],
            supplementalRendererAuthenticator:
                SafeProcessRunnerTestSupplementalRendererAuthenticator()
        )
        let steamEnvironmentPaths = [
            steamEnvironment["DYLD_LIBRARY_PATH"],
            steamEnvironment["DYLD_FRAMEWORK_PATH"],
            steamEnvironment["WINEDLLPATH"]
        ].compactMap { $0 }.joined(separator: ":")

        XCTAssertFalse(steamEnvironmentPaths.contains(supplementalRenderer.path))
        XCTAssertNil(steamEnvironment["D3DMETAL_FRAMEWORK_PATH"])

        let gameEnvironment = try SafeProcessRunner.runnerEnvironment(
            for: launcher,
            base: ["WINEPREFIX": prefix.path],
            graphicsBackend: .d3dMetal,
            supplementalRendererAuthenticator:
                SafeProcessRunnerTestSupplementalRendererAuthenticator()
        )
        let dynamicLibraryPaths = gameEnvironment["DYLD_LIBRARY_PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let frameworkPaths = gameEnvironment["DYLD_FRAMEWORK_PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let wineDLLPaths = gameEnvironment["WINEDLLPATH"]?
            .split(separator: ":")
            .map(String.init) ?? []

        XCTAssertTrue(dynamicLibraryPaths.contains(supplementalRenderer.path))
        XCTAssertTrue(dynamicLibraryPaths.contains(
            supplementalRenderer.appending(path: "wine/x86_64-unix", directoryHint: .isDirectory).path
        ))
        XCTAssertTrue(frameworkPaths.contains(
            supplementalRenderer.appending(path: "external", directoryHint: .isDirectory).path
        ))
        XCTAssertEqual(
            gameEnvironment["D3DMETAL_FRAMEWORK_PATH"],
            supplementalRenderer.appending(
                path: "external/D3DMetal.framework/D3DMetal"
            ).path
        )
        XCTAssertEqual(
            Array(wineDLLPaths.prefix(3)),
            [
                supplementalRenderer.appending(path: "wine", directoryHint: .isDirectory).path,
                supplementalRenderer.appending(path: "wine/x86_64-unix", directoryHint: .isDirectory).path,
                supplementalRenderer.appending(path: "wine/x86_64-windows", directoryHint: .isDirectory).path
            ]
        )

        let modules = try SafeProcessRunner.rendererWindowsModuleFilesByWindowsDirectory(
            for: launcher,
            graphicsBackend: .d3dMetal,
            prefix: prefix,
            supplementalRendererAuthenticator:
                SafeProcessRunnerTestSupplementalRendererAuthenticator()
        )
        XCTAssertEqual(
            modules["system32"]?
                .first(where: { $0.lastPathComponent == "d3d11.dll" })?
                .standardizedFileURL.path,
            supplementalRenderer.appending(path: "wine/x86_64-windows/d3d11.dll")
                .standardizedFileURL.path
        )
    }

    func testManagedSupplementalRendererIsReauthenticatedBeforeDYLDExposureAfterTamper()
        throws {
        let managedRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayManagedRendererTamper-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: managedRoot) }

        let prefix = managedRoot.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let launcher = managedRoot.appending(
            path: "BundledResources/Runners/ForgePlayRuntime/wine/bin/wine"
        )
        let rendererRoot = ForgePlaySupplementalRendererPolicy.rendererRoot(
            forManagedRoot: managedRoot
        )
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
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
        try makeCompleteD3DMetalRenderer(at: rendererRoot)

        let sharedLibrary = rendererRoot.appending(
            path: D3DMetalRendererPayloadContract.sharedLibraryRelativePath
        )
        let expectedSharedLibrary = try Data(contentsOf: sharedLibrary)
        let authenticator =
            SafeProcessRunnerTestSupplementalRendererAuthenticator {
                candidateRoot,
                _ in
                let candidateSharedLibrary = candidateRoot.appending(
                    path: D3DMetalRendererPayloadContract
                        .sharedLibraryRelativePath
                )
                guard try Data(contentsOf: candidateSharedLibrary) ==
                        expectedSharedLibrary else {
                    throw AppleSupplementalRendererAuthenticationError
                        .signatureRejected(
                            candidateSharedLibrary,
                            errSecCSReqFailed
                        )
                }
            }

        let validEnvironment = try SafeProcessRunner.runnerEnvironment(
            for: launcher,
            base: ["WINEPREFIX": prefix.path],
            graphicsBackend: .d3dMetal,
            supplementalRendererAuthenticator: authenticator
        )
        XCTAssertTrue(
            validEnvironment["DYLD_LIBRARY_PATH"]?
                .split(separator: ":")
                .map(String.init)
                .contains(rendererRoot.path) == true
        )

        try Data("post-import-replacement".utf8).write(
            to: sharedLibrary,
            options: .atomic
        )
        do {
            _ = try SafeProcessRunner.runnerEnvironment(
                for: launcher,
                base: ["WINEPREFIX": prefix.path],
                graphicsBackend: .d3dMetal,
                supplementalRendererAuthenticator: authenticator
            )
            XCTFail("A replaced managed native library must not reach DYLD paths.")
        } catch let error as
            AppleSupplementalRendererAuthenticationError {
            guard case .signatureRejected(let rejectedURL, _) = error else {
                return XCTFail("Unexpected authentication error: \(error)")
            }
            XCTAssertEqual(
                rejectedURL.standardizedFileURL,
                sharedLibrary.standardizedFileURL
            )
        } catch {
            XCTFail("Unexpected runner error: \(error)")
        }
    }

    func testRunnerEnvironmentExposesWineExternalFrameworkDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let wineRoot = root.appending(path: "wine", directoryHint: .isDirectory)
        let bin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let external = wineRoot.appending(path: "lib/external", directoryHint: .isDirectory)
        let d3dMetalFramework = external.appending(path: "D3DMetal.framework", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeRendererFixture([
            "libd3dshared.dylib",
            "D3DMetal.framework/D3DMetal",
            "D3DMetal.framework/Resources/Info.plist",
            "D3DMetal.framework/Resources/default.metallib",
            "D3DMetal.framework/Resources/libdxccontainer.dylib",
            "D3DMetal.framework/Resources/libdxcompiler.dylib",
            "D3DMetal.framework/Resources/libdxilconv.dylib",
            "D3DMetal.framework/Resources/libmetalirconverter.dylib"
        ], at: external)
        let launcher = bin.appending(path: "wine")
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let environment = try SafeProcessRunner.runnerEnvironment(
            for: launcher,
            graphicsBackend: .d3dMetal
        )

        XCTAssertTrue(environment["DYLD_LIBRARY_PATH"]?.split(separator: ":").map(String.init).contains(external.path) == true)
        XCTAssertTrue(environment["DYLD_FRAMEWORK_PATH"]?.split(separator: ":").map(String.init).contains(external.path) == true)
        XCTAssertEqual(
            environment["D3DMETAL_FRAMEWORK_PATH"].map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            d3dMetalFramework.appending(path: "D3DMetal").standardizedFileURL.path
        )
    }

    func testRunnerEnvironmentDoesNotExposeIncompleteD3DMetalExternalDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtimeRoot = root.appending(path: "ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let bin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let external = renderer.appending(path: "external", directoryHint: .isDirectory)
        let d3dMetalFramework = external.appending(path: "D3DMetal.framework", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: d3dMetalFramework, withIntermediateDirectories: true)
        try Data("framework".utf8).write(to: d3dMetalFramework.appending(path: "D3DMetal"))
        let launcher = bin.appending(path: "wine")
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let environment = try SafeProcessRunner.runnerEnvironment(
            for: launcher,
            graphicsBackend: .d3dMetal
        )
        let dynamicLibraryPaths = environment["DYLD_LIBRARY_PATH"]?.split(separator: ":").map(String.init) ?? []
        let frameworkPaths = environment["DYLD_FRAMEWORK_PATH"]?.split(separator: ":").map(String.init) ?? []

        XCTAssertFalse(dynamicLibraryPaths.contains(external.path))
        XCTAssertFalse(frameworkPaths.contains(external.path))
        XCTAssertNil(environment["D3DMETAL_FRAMEWORK_PATH"])
    }

    func testExplicitD3DMetalBackendUsesD3DMetalWhenRendererFrameworkExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtimeRoot = root.appending(path: "ForgePlayRuntime", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let bin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let renderer = runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let rendererExternal = renderer.appending(path: "external", directoryHint: .isDirectory)
        let d3dMetalFramework = rendererExternal.appending(path: "D3DMetal.framework", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try makeCompleteD3DMetalRenderer(at: renderer)
        let launcher = bin.appending(path: "wine")
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let environment = try SafeProcessRunner.runnerEnvironment(
            for: launcher,
            graphicsBackend: .d3dMetal
        )

        XCTAssertTrue(environment["WINEDLLOVERRIDES"]?.contains("d3d11,dxgi") == true)
        XCTAssertTrue(environment["WINEDLLOVERRIDES"]?.contains("=n,b") == true)
        XCTAssertTrue(environment["WINEDLLOVERRIDES"]?.contains("winemetal=n,b") == true)
        XCTAssertEqual(environment["VK_ICD_FILENAMES"], "/dev/null")
        XCTAssertEqual(environment["VK_DRIVER_FILES"], "/dev/null")
        XCTAssertEqual(
            environment["D3DMETAL_FRAMEWORK_PATH"].map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            d3dMetalFramework.appending(path: "D3DMetal").standardizedFileURL.path
        )
    }

    func testRunnerEnvironmentExposesBundledVulkanICDConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let wineRoot = root.appending(path: "wine", directoryHint: .isDirectory)
        let bin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let icdDirectory = wineRoot.appending(path: "etc/vulkan/icd.d", directoryHint: .isDirectory)
        let icdFile = icdDirectory.appending(path: "MoltenVK_icd.json")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: icdDirectory, withIntermediateDirectories: true)
        try #"{"ICD":{"library_path":"../../lib/libMoltenVK.dylib","api_version":"1.4.0"}}"#
            .write(to: icdFile, atomically: true, encoding: .utf8)
        let launcher = bin.appending(path: "wine")
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let environment = try SafeProcessRunner.runnerEnvironment(
            for: launcher,
            graphicsBackend: .vulkan
        )

        let icdEnvironmentPath = try XCTUnwrap(environment["VK_ICD_FILENAMES"])
        XCTAssertTrue(icdEnvironmentPath.hasSuffix("/wine/etc/vulkan/icd.d/MoltenVK_icd.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: icdEnvironmentPath))
        XCTAssertEqual(environment["VK_DRIVER_FILES"], icdEnvironmentPath)
    }

    func testDefaultRunnerEnvironmentSuppressesBundledVulkanICDConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let wineRoot = root.appending(path: "wine", directoryHint: .isDirectory)
        let bin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let icdDirectory = wineRoot.appending(path: "etc/vulkan/icd.d", directoryHint: .isDirectory)
        let icdFile = icdDirectory.appending(path: "MoltenVK_icd.json")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: icdDirectory, withIntermediateDirectories: true)
        try #"{"ICD":{"library_path":"../../lib/libMoltenVK.dylib","api_version":"1.4.0"}}"#
            .write(to: icdFile, atomically: true, encoding: .utf8)
        let launcher = bin.appending(path: "wine")
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let environment = try SafeProcessRunner.runnerEnvironment(for: launcher)

        XCTAssertEqual(environment["VK_ICD_FILENAMES"], "/dev/null")
        XCTAssertEqual(environment["VK_DRIVER_FILES"], "/dev/null")
    }

    func testNonWaitingLaunchReportsImmediateFailureExitCode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "fake-runtime")
        let prefix = root.appending(path: "Prefixes/SteamShared", directoryHint: .isDirectory)
        let steamDirectory = prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let steamExecutable = steamDirectory.appending(path: "steam.exe")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data().write(to: steamExecutable)
        try makeManagedD3DMetalRenderer(for: prefix)
        try "#!/bin/sh\nexit 7\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let result = try await makeCuratedRuntimeRunner(
            managedWineProcessJournalEnabled: false
        ).run(.launchSteam(
            runtimeExecutable: launcher,
            prefix: prefix,
            steamExecutable: steamExecutable,
            steamArguments: [],
            graphicsBackend: .d3dMetal,
            logDirectory: logs
        ))

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertTrue(result.waitedForExit)
        XCTAssertFalse(result.succeeded)
    }

    func testSteamInstallerRunsSilentlyAndWaitsForExit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "wine")
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let installer = root.appending(path: "SteamSetup.exe")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data().write(to: installer)
        try "#!/bin/sh\nprintf 'cwd=%s\\n' \"$(/bin/pwd -P)\"\nprintf '%s\\n' \"$@\"\n".write(
            to: launcher,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let result = try await makeCuratedRuntimeRunner(
            managedWineProcessJournalEnabled: false
        ).run(.installSteam(
            runtimeExecutable: launcher,
            prefix: prefix,
            installer: installer,
            logDirectory: logs
        ))
        let output = try String(contentsOf: result.stdoutLog, encoding: .utf8)

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.waitedForExit)
        let outputLines = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(outputLines.count, 3)
        XCTAssertEqual(outputLines.dropFirst().first, installer.path)
        XCTAssertEqual(outputLines.last, "/S")
        let reportedWorkingDirectory = try XCTUnwrap(outputLines.first)
            .replacingOccurrences(of: "cwd=", with: "")
        var expectedStatus = stat()
        var reportedStatus = stat()
        XCTAssertEqual(
            prefix.path.withCString { Darwin.lstat($0, &expectedStatus) },
            0
        )
        XCTAssertEqual(
            reportedWorkingDirectory.withCString {
                Darwin.lstat($0, &reportedStatus)
            },
            0
        )
        XCTAssertEqual(reportedStatus.st_dev, expectedStatus.st_dev)
        XCTAssertEqual(reportedStatus.st_ino, expectedStatus.st_ino)
    }

    func testSteamClientServiceMaintenanceUsesExactWaitedCommands() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlaySteamServiceRunner-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = root.appending(path: "wine")
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let service = SteamClientServiceContract.sourceExecutable(in: prefix)
        let serviceControl = SteamClientServiceContract.serviceControlExecutable(
            in: prefix
        )
        for directory in [
            prefix,
            logs,
            service.deletingLastPathComponent(),
            serviceControl.deletingLastPathComponent()
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try Data("service".utf8).write(to: service)
        try Data("sc".utf8).write(to: serviceControl)
        try """
        #!/bin/sh
        printf 'cwd=%s\\n' "$(/bin/pwd -P)"
        printf '%s\\n' "$@"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        let runner = makeCuratedRuntimeRunner(
            managedWineProcessJournalEnabled: false
        )

        let install = try await runner.run(.maintainSteamClientService(
            runtimeExecutable: launcher,
            prefix: prefix,
            operation: .install,
            logDirectory: logs
        ))
        let installOutput = try String(
            contentsOf: install.stdoutLog,
            encoding: .utf8
        ).split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertTrue(install.succeeded)
        XCTAssertTrue(install.waitedForExit)
        XCTAssertEqual(install.actionName, "installSteamClientService")
        XCTAssertEqual(
            Array(installOutput.dropFirst()),
            [service.path, "/install"]
        )
        let reportedWorkingDirectory = try XCTUnwrap(installOutput.first)
            .replacingOccurrences(of: "cwd=", with: "")
        var expectedStatus = stat()
        var reportedStatus = stat()
        XCTAssertEqual(
            prefix.path.withCString { Darwin.lstat($0, &expectedStatus) },
            0
        )
        XCTAssertEqual(
            reportedWorkingDirectory.withCString {
                Darwin.lstat($0, &reportedStatus)
            },
            0
        )
        XCTAssertEqual(reportedStatus.st_dev, expectedStatus.st_dev)
        XCTAssertEqual(reportedStatus.st_ino, expectedStatus.st_ino)

        let query = try await runner.run(.maintainSteamClientService(
            runtimeExecutable: launcher,
            prefix: prefix,
            operation: .query,
            logDirectory: logs
        ))
        let queryOutput = try String(
            contentsOf: query.stdoutLog,
            encoding: .utf8
        ).split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertTrue(query.succeeded)
        XCTAssertTrue(query.waitedForExit)
        XCTAssertEqual(query.actionName, "querySteamClientService")
        XCTAssertEqual(
            Array(queryOutput.dropFirst()),
            [
                serviceControl.path,
                "query",
                SteamClientServiceContract.serviceName
            ]
        )
        XCTAssertEqual(queryOutput.first, installOutput.first)
    }

    func testWineBinaryInvocationDoesNotPassPrefixAsArgument() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "wine")
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf 'WINEARCH=%s\\n' \"$WINEARCH\"\nprintf 'WINEDLLOVERRIDES=%s\\n' \"$WINEDLLOVERRIDES\"\nprintf '%s\\n' \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let result = try await makeCuratedRuntimeRunner(
            managedWineProcessJournalEnabled: false
        ).run(.initializePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let output = try String(contentsOf: result.stdoutLog, encoding: .utf8)

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(
            output.hasPrefix("WINEARCH=win64\nWINEDLLOVERRIDES=mscoree,mshtml=\nwineboot\n-u\n"),
            output
        )
        XCTAssertFalse(output.contains(prefix.path))
    }

    func testPrefixRuntimeMigrationUsesExplicitForcedWineBootUpdate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "wine")
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf 'WINEARCH=%s\\n' \"$WINEARCH\"\nprintf 'WINEDLLOVERRIDES=%s\\n' \"$WINEDLLOVERRIDES\"\nprintf '%s\\n' \"$@\"\n"
            .write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let result = try await makeCuratedRuntimeRunner(
            managedWineProcessJournalEnabled: false
        ).run(.migratePrefixRuntime(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let output = try String(contentsOf: result.stdoutLog, encoding: .utf8)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.actionName, "migratePrefixRuntime")
        XCTAssertEqual(
            output,
            "WINEARCH=win64\nWINEDLLOVERRIDES=mscoree,mshtml=\nwineboot\n-u\n"
        )
    }

    func testWaitForWinePrefixUsesDirectWineserverWhenBundledRuntimeProvidesIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = try makeWineRunner(
            in: root,
            wineserverScript: """
            #!/bin/sh
            printf 'WINEPREFIX=%s\\n' "$WINEPREFIX"
            printf '%s\\n' "$@"
            exit 0
            """
        )
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let result = try await makeCuratedRuntimeRunner().run(.waitForWinePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let output = try String(contentsOf: result.stdoutLog, encoding: .utf8)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.actionName, "waitForWinePrefix")
        XCTAssertEqual(output, "WINEPREFIX=\(prefix.path)\n-w\n")
    }

    func testDescriptorBoundPrefixCommandsBindTheFinalSelectedExecutable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayDescriptorPrefixCommands-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let bin = root.appending(
            path: "ForgePlayRuntime/wine/bin",
            directoryHint: .isDirectory
        )
        let launcher = bin.appending(path: "wine")
        let wineserver = bin.appending(path: "wineserver")
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: bin,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        let launcherScript = """
        #!/bin/sh
        launcher_name=${0##*/}
        printf 'launcher=%s\\n' "$launcher_name"
        printf 'argument=%s\\n' "$@"
        exit 0
        """
        try launcherScript.write(
            to: launcher,
            atomically: true,
            encoding: .utf8
        )
        try launcherScript.write(
            to: wineserver,
            atomically: true,
            encoding: .utf8
        )
        for executable in [launcher, wineserver] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        try installAuthenticatedRuntimePayloadFixture(for: launcher)
        let runner = makeCuratedRuntimeRunner(
            managedWineProcessJournalEnabled: false,
            runtimeLaunchObjectIdentityProvider: { executable in
                try RuntimeManifestResolver().launchObjectIdentity(
                    for: executable
                )
            }
        )

        let initializeResult = try await runner.run(.initializePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let waitResult = try await runner.run(.waitForWinePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let initializeOutput = try String(
            contentsOf: initializeResult.stdoutLog,
            encoding: .utf8
        )
        let waitOutput = try String(
            contentsOf: waitResult.stdoutLog,
            encoding: .utf8
        )

        XCTAssertTrue(initializeResult.succeeded)
        XCTAssertEqual(
            initializeOutput,
            "launcher=wine\nargument=wineboot\nargument=-u\n"
        )
        XCTAssertTrue(waitResult.succeeded)
        XCTAssertEqual(
            waitOutput,
            "launcher=wineserver\nargument=-w\n"
        )
    }

    func testWineProbeUsesVersionWithoutInitializingPrefix() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "wine")
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let result = try await makeCuratedRuntimeRunner().run(.probeRuntime(
            executable: launcher,
            logDirectory: logs
        ))
        let output = try String(contentsOf: result.stdoutLog, encoding: .utf8)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(output, "--version\n")
        XCTAssertFalse(output.contains("wineboot"))
    }

    func testRuntimeMSIInstallerUsesMsiexec() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "wine")
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        let installer = root.appending(path: "xnafx40_redist.msi")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data().write(to: installer)
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let result = try await makeCuratedRuntimeRunner(
            managedWineProcessJournalEnabled: false
        ).run(.installRuntime(
            runtimeExecutable: launcher,
            prefix: prefix,
            installer: installer,
            runtime: .xna40,
            logDirectory: logs
        ))
        let output = try String(contentsOf: result.stdoutLog, encoding: .utf8)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(output, "msiexec\n/i\n\(installer.path)\n")
    }

    func testBundledRuntimeInvocationAddsBundledLibraryPaths() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtimeRoot = root.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let frameworks = runtimeRoot.appending(path: "Frameworks", directoryHint: .isDirectory)
        let renderer = frameworks.appending(path: "renderer/dxmt", directoryHint: .isDirectory)
        let wineRoot = runtimeRoot.appending(path: "wine", directoryHint: .isDirectory)
        let bin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let libWine = wineRoot.appending(path: "lib/wine", directoryHint: .isDirectory)
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let logs = root.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libWine, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data().write(to: frameworks.appending(path: "libinotify.0.dylib"))

        let launcher = bin.appending(path: "wine")
        let wineLoader = bin.appending(path: "wine.bin")
        let wineserver = bin.appending(path: "wineserver")
        try """
        #!/bin/sh
        printf 'DYLD_LIBRARY_PATH=%s\\n' "$DYLD_LIBRARY_PATH"
        printf 'DYLD_FALLBACK_LIBRARY_PATH=%s\\n' "$DYLD_FALLBACK_LIBRARY_PATH"
        printf 'PATH=%s\\n' "$PATH"
        printf 'WINELOADER=%s\\n' "$WINELOADER"
        printf 'WINESERVER=%s\\n' "$WINESERVER"
        printf 'WINEDLLPATH=%s\\n' "$WINEDLLPATH"
        printf '%s\\n' "$@"
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: wineLoader, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: wineserver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineLoader.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserver.path)

        let environment = try SafeProcessRunner.runnerEnvironment(
            for: launcher,
            base: [
                "WINEPREFIX": prefix.path,
                "WINE_MACH_SERVICE_NAME": "stale.group.namespace"
            ],
            sandboxEnabled: false,
            primaryApplicationGroupIdentifier: nil
        )
        let result = try await makeCuratedRuntimeRunner().run(.initializePrefix(
            runtimeExecutable: launcher,
            prefix: prefix,
            logDirectory: logs
        ))
        let output = try String(contentsOf: result.stdoutLog, encoding: .utf8)

        XCTAssertTrue(
            result.succeeded,
            "exit=\(result.exitCode) outcome=\(result.outcome.rawValue) stderr=\(result.stderrLog.path) output=\(output)"
        )
        XCTAssertEqual(environment["WINEPREFIX"], prefix.path)
        XCTAssertEqual(
            environment["WINE_SERVER_ROOT"],
            prefix.appending(path: ".forgeplay-wineserver", directoryHint: .isDirectory).path
        )
        XCTAssertNil(environment["WINE_MACH_SERVICE_NAME"])
        let applicationGroupIdentifier = "group.com.forgeplay.client"
        let groupContainer = root.appending(
            path: "GroupContainer",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: groupContainer,
            withIntermediateDirectories: true
        )
        let directReleaseEnvironment = try SafeProcessRunner.runnerEnvironment(
            for: launcher,
            base: ["WINEPREFIX": prefix.path],
            sandboxEnabled: false,
            primaryApplicationGroupIdentifier: applicationGroupIdentifier,
            applicationGroupContainerResolver: { identifier in
                XCTAssertEqual(identifier, applicationGroupIdentifier)
                return groupContainer
            }
        )
        XCTAssertEqual(
            directReleaseEnvironment["WINE_SERVER_ROOT"],
            SafeProcessRunner.wineServerRoot(
                forPrefix: prefix,
                sandboxEnabled: true,
                applicationGroupContainerURL: groupContainer
            ).path
        )
        XCTAssertEqual(
            directReleaseEnvironment["WINE_MACH_SERVICE_NAME"],
            SafeProcessRunner.wineMachServiceName(
                forPrefix: prefix,
                applicationGroupIdentifier: applicationGroupIdentifier
            )
        )
        XCTAssertTrue(environment["DYLD_LIBRARY_PATH"]?.contains(wineRoot.appending(path: "lib").path) == true)
        XCTAssertFalse(environment["DYLD_LIBRARY_PATH"]?.contains(frameworks.path) == true)
        XCTAssertFalse(environment["DYLD_LIBRARY_PATH"]?.contains(renderer.path) == true)
        XCTAssertFalse(environment["DYLD_FALLBACK_LIBRARY_PATH"]?.contains(frameworks.path) == true)
        XCTAssertTrue(output.contains("PATH=\(bin.path):"), output)
        XCTAssertTrue(output.contains("WINELOADER=\(wineLoader.path)"), output)
        XCTAssertTrue(output.contains("WINESERVER=\(wineserver.path)"), output)
        XCTAssertTrue(output.contains("WINEDLLPATH=\(libWine.path)"), output)
        XCTAssertTrue(output.contains("wineboot\n-u\n"), output)
    }

    func testSandboxWineServerRootUsesPrefixScopedApplicationGroupCache() {
        let prefix = URL(fileURLWithPath: "/Volumes/Games/Prefixes/SteamShared", isDirectory: true)
        let applicationGroupContainer = URL(
            fileURLWithPath: "/Users/test/Library/Group Containers/TEAMID.com.ForgePlay.app",
            isDirectory: true
        )
        let scope = SafeProcessRunner.wineServerScopeIdentifier(forPrefix: prefix)

        XCTAssertEqual(
            SafeProcessRunner.wineServerRoot(
                forPrefix: prefix,
                sandboxEnabled: true,
                applicationGroupContainerURL: applicationGroupContainer
            ).path,
            applicationGroupContainer.appending(
                path: "Library/Caches/ForgePlay/WineServer/\(scope)",
                directoryHint: .isDirectory
            ).path
        )
    }

    func testPrepareWineServerRootCreatesPrivateDirectoryWithoutFollowingSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayWineServerRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let serverRoot = root.appending(
            path: "Library/Caches/ForgePlay/WineServer/prefix-scope",
            directoryHint: .isDirectory
        )
        try SafeProcessRunner.prepareWineServerRoot(serverRoot, trustedAncestor: root)

        try FileSystemItemPolicy.requireNonSymlinkDirectory(serverRoot)
        let attributes = try FileManager.default.attributesOfItem(atPath: serverRoot.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)

        let outside = root.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let unsafeRoot = root.appending(path: "Unsafe", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: unsafeRoot, withDestinationURL: outside)

        XCTAssertThrowsError(
            try SafeProcessRunner.prepareWineServerRoot(
                unsafeRoot.appending(path: "WineServer", directoryHint: .isDirectory),
                trustedAncestor: root
            )
        ) { error in
            guard case SafeProcessRunnerError.unsafeWineServerRoot = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testSandboxWineMachServiceNameUsesApplicationGroupAndStablePrefixDigest() {
        let prefix = URL(fileURLWithPath: "/Volumes/Games/Prefixes/SteamShared", isDirectory: true)
        let serviceName = SafeProcessRunner.wineMachServiceName(
            forPrefix: prefix,
            applicationGroupIdentifier: "TEAMID.com.ForgePlay.app"
        )

        XCTAssertTrue(serviceName.hasPrefix("TEAMID.com.ForgePlay.app.wineserver."), serviceName)
        XCTAssertEqual(serviceName, SafeProcessRunner.wineMachServiceName(
            forPrefix: prefix,
            applicationGroupIdentifier: "TEAMID.com.ForgePlay.app"
        ))
        XCTAssertNotEqual(serviceName, SafeProcessRunner.wineMachServiceName(
            forPrefix: prefix.appending(path: "Other", directoryHint: .isDirectory),
            applicationGroupIdentifier: "TEAMID.com.ForgePlay.app"
        ))
    }

    func testBundledRuntimeInvocationSurfacesUnreadableRendererDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: "BundledResources/Runners/ForgePlayRuntime/Frameworks/renderer").path)
            try? FileManager.default.removeItem(at: root)
        }

        let runtimeRoot = root.appending(path: "BundledResources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let frameworks = runtimeRoot.appending(path: "Frameworks", directoryHint: .isDirectory)
        let renderer = frameworks.appending(path: "renderer", directoryHint: .isDirectory)
        let bin = runtimeRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: renderer, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let launcher = bin.appending(path: "wine")
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: renderer.path)

        do {
            _ = try SafeProcessRunner.runnerEnvironment(for: launcher)
            XCTFail("Expected unreadable renderer directory to fail library path discovery")
        } catch SafeProcessRunnerError.runnerLibrarySearchFailed(let url, _) {
            XCTAssertEqual(url.standardizedFileURL.path, renderer.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCuratedD3DMetalNVIDIALayoutBuilds64BitGameRendererPolicyWithoutWoW64Payload() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCuratedD3DMetalRenderer-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let wineRoot = root.appending(path: "wine", directoryHint: .isDirectory)
        let bin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let launcher = bin.appending(path: "wine")
        let renderer = root.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let d9VKRenderer = root.appending(path: "Frameworks/renderer/d9vk", directoryHint: .isDirectory)
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try makeCompleteD3DMetalRenderer(at: renderer)
        try makeCompleteD9VKRenderer(at: d9VKRenderer)

        let environment = try SafeProcessRunner.steamGameRendererPolicyEnvironment(
            for: launcher,
            prefix: prefix,
            graphicsBackend: .d3dMetal,
            rendererSelection: .d3dMetalNVIDIA,
            logDirectory: root
        )

        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_POLICY"], "d3dMetal")
        XCTAssertEqual(
            environment["FORGEPLAY_GAME_RENDERER_REQUESTED"],
            SteamRendererPolicySelection.d3dMetalNVIDIA.rawValue
        )
        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_COMPONENTS_X64"], "d3dmetal")
        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_COMPONENTS_X86"], "")
        let rendererWineRoot = renderer.appending(path: "wine").path
        let rendererWineDLLPath = try XCTUnwrap(
            environment["FORGEPLAY_GAME_RENDERER_ENV_WINEDLLPATH"]
        )
        let rendererWineDLLPathEntries = rendererWineDLLPath
            .split(separator: ":")
            .map(String.init)
        XCTAssertEqual(rendererWineDLLPathEntries.first, rendererWineRoot)
        XCTAssertFalse(
            rendererWineDLLPathEntries.contains(
                renderer.appending(path: "wine/x86_64-windows").path
            )
        )
        XCTAssertFalse(
            rendererWineDLLPathEntries.contains(
                renderer.appending(path: "wine/x86_64-unix").path
            )
        )
        XCTAssertTrue(
            environment["FORGEPLAY_GAME_RENDERER_DLL_PATH_X64"]?
                .contains("\\Frameworks\\renderer\\d3dmetal\\wine\\x86_64-windows") == true
        )
        XCTAssertFalse(
            environment["FORGEPLAY_GAME_RENDERER_DLL_PATH_X64"]?
                .contains("\\Frameworks\\renderer\\d9vk\\") == true
        )
        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_DLL_PATH_X86"], "")
        XCTAssertTrue(
            environment["FORGEPLAY_GAME_RENDERER_ENV_D3DMETAL_FRAMEWORK_PATH"]?
                .contains("D3DMetal.framework") == true
        )
        XCTAssertEqual(
            environment["FORGEPLAY_GAME_RENDERER_ENV_D3DM_ENABLE_METALFX"],
            "1"
        )
        let ngxWindowsDirectory = try XCTUnwrap(
            environment["FORGEPLAY_GAME_RENDERER_ENV_D3DM_NVNGX_PATH"]
        )
        XCTAssertTrue(
            ngxWindowsDirectory.contains(
                "/.forgeplay/renderer-bridges/d3dmetal/"
            )
        )
        let ngxBridgeRoot = URL(
            fileURLWithPath: ngxWindowsDirectory,
            isDirectory: true
        )
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        XCTAssertTrue(D3DMetalNGXBridgeContract.isUsable(at: ngxBridgeRoot))
        let derivedNGX = URL(
            fileURLWithPath: ngxWindowsDirectory,
            isDirectory: true
        ).appending(path: "nvngx.dll")
        let sourceNGX = renderer.appending(
            path: D3DMetalNGXBridgeContract.sourceWindowsModuleRelativePath
        )
        XCTAssertEqual(
            try Data(contentsOf: derivedNGX),
            try Data(contentsOf: sourceNGX)
        )
        XCTAssertTrue(
            environment["FORGEPLAY_GAME_RENDERER_ENV_WINEDLLOVERRIDES"]?
                .contains("nvngx") == true
        )
        XCTAssertTrue(
            environment["FORGEPLAY_GAME_RENDERER_DLL_PATH_X64"]?
                .contains("\\.forgeplay\\renderer-bridges\\d3dmetal\\") == true
        )
        XCTAssertFalse(environment.keys.contains { $0.contains("_PROFILE_") })
    }

    func testD3DMetalNVIDIASelectionScopesVendorAndNetworkIdentityToGameEnvironment() throws {
        let fixture = try makeRendererRoutingFixture("D3DMetalNVIDIACompatibility")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try makeCompleteD3DMetalRenderer(
            at: fixture.rendererRoot.appending(
                path: "d3dmetal",
                directoryHint: .isDirectory
            )
        )

        let standardEnvironment =
            try SafeProcessRunner.steamGameRendererPolicyEnvironment(
                for: fixture.launcher,
                prefix: fixture.prefix,
                graphicsBackend: .d3dMetal,
                rendererSelection: .d3dMetal,
                networkSelection: .standard,
                logDirectory: fixture.root
            )
        let compatibilityEnvironment =
            try SafeProcessRunner.steamGameRendererPolicyEnvironment(
                for: fixture.launcher,
                prefix: fixture.prefix,
                graphicsBackend: .d3dMetal,
                rendererSelection: .d3dMetalNVIDIA,
                networkSelection: .wifiIdentity,
                logDirectory: fixture.root
            )

        XCTAssertEqual(
            standardEnvironment["FORGEPLAY_GAME_RENDERER_REQUESTED"],
            SteamRendererPolicySelection.d3dMetal.rawValue
        )
        XCTAssertEqual(
            standardEnvironment["FORGEPLAY_GAME_RENDERER_ENV_D3DM_VENDOR_ID"],
            "__FORGEPLAY_UNSET__"
        )
        XCTAssertEqual(
            standardEnvironment[
                "FORGEPLAY_GAME_RENDERER_ENV_D3DM_ENABLE_METALFX"
            ],
            "__FORGEPLAY_UNSET__"
        )
        XCTAssertEqual(
            standardEnvironment[
                "FORGEPLAY_GAME_RENDERER_ENV_D3DM_NVNGX_PATH"
            ],
            "__FORGEPLAY_UNSET__"
        )
        XCTAssertEqual(
            standardEnvironment[
                "FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP"
            ],
            "__FORGEPLAY_UNSET__"
        )
        XCTAssertEqual(
            standardEnvironment[
                "FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NETWORK_PROFILE"
            ],
            SteamNetworkCompatibilitySelection.standard.rawValue
        )
        XCTAssertEqual(
            compatibilityEnvironment["FORGEPLAY_GAME_RENDERER_REQUESTED"],
            SteamRendererPolicySelection.d3dMetalNVIDIA.rawValue
        )
        XCTAssertEqual(
            compatibilityEnvironment["FORGEPLAY_GAME_RENDERER_ENV_D3DM_VENDOR_ID"],
            "0x10de"
        )
        XCTAssertEqual(
            compatibilityEnvironment[
                "FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP"
            ],
            "1"
        )
        XCTAssertEqual(
            compatibilityEnvironment[
                "FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NETWORK_PROFILE"
            ],
            SteamNetworkCompatibilitySelection.wifiIdentity.rawValue
        )
        XCTAssertEqual(
            compatibilityEnvironment[
                SteamBaseRuntimeCompatibilityHelperContract.environmentKey
            ],
            SteamBaseRuntimeCompatibilityHelperContract.encodedRules
        )
        XCTAssertEqual(
            SteamBaseRuntimeCompatibilityHelperContract.blueArchivePathSuffixes
                .count,
            3
        )
    }

    func testRendererPreferenceRejectsAnInconsistentCompatibilitySelection() throws {
        let fixture = try makeRendererRoutingFixture("InconsistentCompatibility")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try SafeProcessRunner.steamGameRendererPolicyEnvironment(
                for: fixture.launcher,
                prefix: fixture.prefix,
                graphicsBackend: .d3dMetal,
                rendererSelection: .dxmt,
                networkSelection: .standard,
                logDirectory: fixture.root
            )
        ) { error in
            guard case SafeProcessRunnerError.invalidSteamCompatibilitySelection =
                    error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testD3DMetalNGXBridgeRepairsAReplacedDerivedModuleWithoutTouchingSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlayD3DMetalNGXRepair-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = root.appending(path: "wine/bin/wine")
        let renderer = root.appending(
            path: "Frameworks/renderer/d3dmetal",
            directoryHint: .isDirectory
        )
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(
            to: launcher,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        try makeCompleteD3DMetalRenderer(at: renderer)

        let firstEnvironment = try SafeProcessRunner.steamGameRendererPolicyEnvironment(
            for: launcher,
            prefix: prefix,
            graphicsBackend: .d3dMetal,
            rendererSelection: .d3dMetalNVIDIA,
            logDirectory: root
        )
        let ngxDirectory = URL(
            fileURLWithPath: try XCTUnwrap(
                firstEnvironment["FORGEPLAY_GAME_RENDERER_ENV_D3DM_NVNGX_PATH"]
            ),
            isDirectory: true
        )
        let derivedNGX = ngxDirectory.appending(path: "nvngx.dll")
        let sourceNGX = renderer.appending(
            path: D3DMetalNGXBridgeContract.sourceWindowsModuleRelativePath
        )
        let originalSource = try Data(contentsOf: sourceNGX)
        try Data("replaced bridge".utf8).write(to: derivedNGX, options: [.atomic])

        let secondEnvironment = try SafeProcessRunner.steamGameRendererPolicyEnvironment(
            for: launcher,
            prefix: prefix,
            graphicsBackend: .d3dMetal,
            rendererSelection: .d3dMetalNVIDIA,
            logDirectory: root
        )

        XCTAssertEqual(
            secondEnvironment["FORGEPLAY_GAME_RENDERER_ENV_D3DM_NVNGX_PATH"],
            ngxDirectory.path
        )
        XCTAssertEqual(try Data(contentsOf: sourceNGX), originalSource)
        XCTAssertEqual(try Data(contentsOf: derivedNGX), originalSource)
        XCTAssertTrue(
            D3DMetalNGXBridgeContract.isUsable(
                at: ngxDirectory
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
            )
        )
    }

    func testCanonicalAppleD3DMetalFrameworkBuildsGameRendererPolicy() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCanonicalD3DMetalRenderer-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let bin = root.appending(path: "wine/bin", directoryHint: .isDirectory)
        let launcher = bin.appending(path: "wine")
        let renderer = root.appending(path: "Frameworks/renderer/d3dmetal", directoryHint: .isDirectory)
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try makeCompleteD3DMetalRenderer(at: renderer)
        try canonicalizeD3DMetalFramework(at: renderer)

        let environment = try SafeProcessRunner.steamGameRendererPolicyEnvironment(
            for: launcher,
            prefix: prefix,
            graphicsBackend: .d3dMetal,
            logDirectory: root
        )

        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_POLICY"], "d3dMetal")
        XCTAssertEqual(
            environment["FORGEPLAY_GAME_RENDERER_ENV_D3DMETAL_FRAMEWORK_PATH"],
            renderer.appending(path: "external/D3DMetal.framework/D3DMetal").path
        )
    }

    func testCuratedDXVKLayoutIsResolvedForBundledRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayStandardDXVKRenderer-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let wineRoot = root.appending(path: "wine", directoryHint: .isDirectory)
        let bin = wineRoot.appending(path: "bin", directoryHint: .isDirectory)
        let launcher = bin.appending(path: "wine")
        let dxvk = root.appending(path: "Frameworks/renderer/dxvk/wine", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        for relativePath in [
            "i386-windows/d3d8.dll",
            "i386-windows/d3d9.dll",
            "i386-windows/d3d10core.dll",
            "i386-windows/d3d11.dll",
            "i386-windows/dxgi.dll",
            "x86_64-windows/d3d8.dll",
            "x86_64-windows/d3d9.dll",
            "x86_64-windows/d3d10core.dll",
            "x86_64-windows/d3d11.dll",
            "x86_64-windows/dxgi.dll"
        ] {
            let file = dxvk.appending(path: relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
        }

        let modules = try SafeProcessRunner.rendererWindowsModuleFilesByWindowsDirectory(
            for: launcher,
            graphicsBackend: .vulkan
        )

        let expectedModules: Set<String> = [
            "d3d8.dll",
            "d3d9.dll",
            "d3d10core.dll",
            "d3d11.dll",
            "dxgi.dll"
        ]
        XCTAssertEqual(
            Set(modules["system32", default: []].map(\.lastPathComponent)),
            expectedModules
        )
        XCTAssertEqual(
            Set(modules["syswow64", default: []].map(\.lastPathComponent)),
            expectedModules
        )
    }

    func testManualD9VKSelectionDoesNotFallBackToDXVKWhenD9VKIsIncomplete() throws {
        let fixture = try makeRendererRoutingFixture("D9VKFallback")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeRendererComponent(
            "dxvk",
            relativePaths: Self.completeDXVKModulePaths,
            under: fixture.rendererRoot
        )
        try writeRendererComponent(
            "d9vk",
            relativePaths: ["wine/x86_64-windows/d3d9.dll"],
            under: fixture.rendererRoot
        )

        XCTAssertThrowsError(try SafeProcessRunner.steamGameRendererPolicyEnvironment(
            for: fixture.launcher,
            prefix: fixture.prefix,
            graphicsBackend: .d9vk,
            logDirectory: fixture.root
        )) { error in
            guard case SafeProcessRunnerError.gameRendererPayloadMissing = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testManualDXMTSelectionDoesNotInferPayloadFromLegacyEmptyDirectories() throws {
        let fixture = try makeRendererRoutingFixture("NoSyntheticDXMT")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeRendererComponent(
            "dxvk",
            relativePaths: Self.completeDXVKModulePaths,
            under: fixture.rendererRoot
        )
        for relativePath in [
            "dxmt/wine/i386-windows",
            "dxmt/wine/x86_64-windows",
            "dxmt/wine/x86_64-unix"
        ] {
            try FileManager.default.createDirectory(
                at: fixture.rendererRoot.appending(path: relativePath, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }

        XCTAssertThrowsError(try SafeProcessRunner.steamGameRendererPolicyEnvironment(
            for: fixture.launcher,
            prefix: fixture.prefix,
            graphicsBackend: .dxmt,
            logDirectory: fixture.root
        )) { error in
            guard case SafeProcessRunnerError.gameRendererPayloadMissing = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testManualDXMTSelectionPublishesOnlyTheDXMTPayload() throws {
        let fixture = try makeRendererRoutingFixture("NoSyntheticD3DMetal")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeRendererComponent(
            "dxvk",
            relativePaths: Self.completeDXVKModulePaths,
            under: fixture.rendererRoot
        )
        try writeRendererComponent(
            "dxmt",
            relativePaths: Self.completeDXMTModulePaths,
            under: fixture.rendererRoot
        )
        try writeRendererComponent(
            "d9vk",
            relativePaths: [
                "wine/i386-windows/d3d9.dll",
                "wine/x86_64-windows/d3d9.dll"
            ],
            under: fixture.rendererRoot
        )

        let environment = try SafeProcessRunner.steamGameRendererPolicyEnvironment(
            for: fixture.launcher,
            prefix: fixture.prefix,
            graphicsBackend: .dxmt,
            networkSelection: .ethernetIdentity,
            logDirectory: fixture.root
        )

        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_POLICY"], "dxmt")
        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_REQUESTED"], "dxmt")
        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_COMPONENTS_X64"], "dxmt")
        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_COMPONENTS_X86"], "dxmt")
        let values = environment.values.joined(separator: "\n")
        XCTAssertTrue(values.contains("/renderer/dxmt/") || values.contains("\\renderer\\dxmt\\"))
        XCTAssertFalse(values.contains("/renderer/dxvk/") || values.contains("\\renderer\\dxvk\\"))
        XCTAssertFalse(values.contains("/renderer/d9vk/") || values.contains("\\renderer\\d9vk\\"))
        XCTAssertFalse(values.contains("/renderer/d3dmetal/") || values.contains("\\renderer\\d3dmetal\\"))
        XCTAssertFalse(environment.keys.contains { $0.contains("_PROFILE_") })
        XCTAssertEqual(
            environment[
                "FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NETWORK_PROFILE"
            ],
            SteamNetworkCompatibilitySelection.ethernetIdentity.rawValue
        )
        XCTAssertEqual(
            environment["FORGEPLAY_GAME_RENDERER_ENV_D3DM_VENDOR_ID"],
            "__FORGEPLAY_UNSET__"
        )
        XCTAssertNil(environment["FORGEPLAY_GAME_RENDERER_AVAILABLE_PROFILES"])
        XCTAssertNil(environment["FORGEPLAY_GAME_RENDERER_UNAVAILABLE_PROFILES"])
    }

    func testManualSupplementalD3DMetalSelectionIgnoresOtherRendererPayloads() throws {
        let managedRoot = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayManagedManualD3DMetal-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: managedRoot) }

        let launcher = managedRoot.appending(
            path: "BundledResources/Runners/ForgePlayRuntime/wine/bin/wine"
        )
        let prefix = managedRoot.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let supplementalRenderer = ForgePlaySupplementalRendererPolicy.rendererRoot(
            forManagedRoot: managedRoot
        )
        let d9VKRenderer = managedRoot.appending(
            path: "BundledResources/Runners/ForgePlayRuntime/Frameworks/renderer/d9vk",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        try makeCompleteD3DMetalRenderer(at: supplementalRenderer)
        try makeCompleteD9VKRenderer(at: d9VKRenderer)

        let environment = try SafeProcessRunner.steamGameRendererPolicyEnvironment(
            for: launcher,
            prefix: prefix,
            graphicsBackend: .d3dMetal,
            logDirectory: managedRoot,
            supplementalRendererAuthenticator:
                SafeProcessRunnerTestSupplementalRendererAuthenticator()
        )

        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_POLICY"], "d3dMetal")
        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_REQUESTED"], "d3dMetal")
        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_COMPONENTS_X64"], "d3dmetal")
        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_COMPONENTS_X86"], "")
        XCTAssertEqual(
            environment["FORGEPLAY_GAME_RENDERER_ENV_D3DMETAL_FRAMEWORK_PATH"],
            supplementalRenderer.appending(
                path: "external/D3DMetal.framework/D3DMetal"
            ).path
        )
        let values = environment.values.joined(separator: "\n")
        XCTAssertTrue(values.contains(supplementalRenderer.path))
        XCTAssertFalse(values.contains("/renderer/d9vk/") || values.contains("\\renderer\\d9vk\\"))
        XCTAssertFalse(environment.keys.contains { $0.contains("_PROFILE_") })
        XCTAssertNil(environment["FORGEPLAY_GAME_RENDERER_AVAILABLE_PROFILES"])
        XCTAssertNil(environment["FORGEPLAY_GAME_RENDERER_UNAVAILABLE_PROFILES"])
    }

    func testPackagedD3DMetalRendererDoesNotExposeD3D12WhenCoreBridgeHalfIsMissing() throws {
        for missingRelativePath in [
            "wine/x86_64-unix/d3d12.so",
            "wine/x86_64-windows/d3d12.dll"
        ] {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "ForgePlayIncompleteD3DMetal-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: root) }

            let runtimeRoot = root.appending(path: "ForgePlayRuntime", directoryHint: .isDirectory)
            let bin = runtimeRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
            let launcher = bin.appending(path: "wine")
            let renderer = runtimeRoot.appending(
                path: "Frameworks/renderer/d3dmetal",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
            try makeCompleteD3DMetalRenderer(at: renderer)
            try FileManager.default.removeItem(at: renderer.appending(path: missingRelativePath))

            let modules = try SafeProcessRunner.rendererWindowsModuleFilesByWindowsDirectory(
                for: launcher,
                graphicsBackend: .d3dMetal
            )

            let moduleNames = Set(modules.values.flatMap { $0 }.map(\.lastPathComponent))
            XCTAssertFalse(
                moduleNames.contains("d3d12.dll"),
                "Incomplete D3D12 route was exposed after removing \(missingRelativePath)"
            )
            XCTAssertTrue(moduleNames.contains("d3d11.dll"))
            XCTAssertTrue(moduleNames.contains("dxgi.dll"))
        }
    }

    func testStandardD3DMetalD3D12RouteDoesNotDependOnNVIDIAProviderPayload() throws {
        let fixture = try makeRendererRoutingFixture("StandardD3DMetalWithoutNVIDIA")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let renderer = fixture.rendererRoot.appending(
            path: "d3dmetal",
            directoryHint: .isDirectory
        )
        try makeCompleteD3DMetalRenderer(at: renderer)
        for relativePath in D3DMetalRendererPayloadContract
            .nvidiaMetalFXClosureRelativePaths {
            try FileManager.default.removeItem(
                at: renderer.appending(path: relativePath)
            )
        }

        let environment = try SafeProcessRunner
            .steamGameRendererPolicyEnvironment(
                for: fixture.launcher,
                prefix: fixture.prefix,
                graphicsBackend: .d3dMetal,
                rendererSelection: .d3dMetal,
                logDirectory: fixture.root
            )

        XCTAssertEqual(
            environment["FORGEPLAY_GAME_RENDERER_REQUESTED"],
            SteamRendererPolicySelection.d3dMetal.rawValue
        )
        XCTAssertTrue(
            environment["FORGEPLAY_GAME_RENDERER_ENV_WINEDLLOVERRIDES"]?
                .contains("d3d12") == true
        )
        XCTAssertFalse(
            environment["FORGEPLAY_GAME_RENDERER_ENV_WINEDLLOVERRIDES"]?
                .contains("nvapi") == true
        )
        XCTAssertEqual(
            environment["FORGEPLAY_GAME_RENDERER_ENV_D3DM_ENABLE_METALFX"],
            "__FORGEPLAY_UNSET__"
        )
        XCTAssertEqual(
            environment["FORGEPLAY_GAME_RENDERER_ENV_D3DM_NVNGX_PATH"],
            "__FORGEPLAY_UNSET__"
        )
    }

    func testD3DMetalNVIDIASelectionRejectsMissingProviderPayloadBeforeMaterialization() throws {
        let fixture = try makeRendererRoutingFixture("NVIDIAPayloadIncomplete")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let renderer = fixture.rendererRoot.appending(
            path: "d3dmetal",
            directoryHint: .isDirectory
        )
        try makeCompleteD3DMetalRenderer(at: renderer)
        try FileManager.default.removeItem(
            at: renderer.appending(
                path: D3DMetalNGXBridgeContract
                    .sourceWindowsModuleRelativePath
            )
        )

        XCTAssertThrowsError(
            try SafeProcessRunner.steamGameRendererPolicyEnvironment(
                for: fixture.launcher,
                prefix: fixture.prefix,
                graphicsBackend: .d3dMetal,
                rendererSelection: .d3dMetalNVIDIA,
                logDirectory: fixture.root
            )
        ) { error in
            guard case SafeProcessRunnerError.gameRendererPayloadMissing =
                    error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.prefix.appending(
                    path: ".forgeplay/renderer-bridges/d3dmetal",
                    directoryHint: .isDirectory
                ).path
            )
        )
    }

    func testPackagedD3DMetalRendererRejectsIndependentSharedLibraryCopies() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCopiedD3DMetalModule-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtimeRoot = root.appending(path: "ForgePlayRuntime", directoryHint: .isDirectory)
        let bin = runtimeRoot.appending(path: "wine/bin", directoryHint: .isDirectory)
        let launcher = bin.appending(path: "wine")
        let renderer = runtimeRoot.appending(
            path: "Frameworks/renderer/d3dmetal",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try makeCompleteD3DMetalRenderer(at: renderer)

        let dxgiUnixModule = renderer.appending(path: "wine/x86_64-unix/dxgi.so")
        let sharedLibrary = renderer.appending(
            path: D3DMetalRendererPayloadContract.sharedLibraryRelativePath
        )
        try FileManager.default.removeItem(at: dxgiUnixModule)
        try Data(contentsOf: sharedLibrary).write(to: dxgiUnixModule)

        let modules = try SafeProcessRunner.rendererWindowsModuleFilesByWindowsDirectory(
            for: launcher,
            graphicsBackend: .d3dMetal
        )
        XCTAssertTrue(modules.values.allSatisfy(\.isEmpty))
    }

    private func makeCompleteD3DMetalRenderer(at renderer: URL) throws {
        try writeRendererFixture([
            "external/libd3dshared.dylib",
            "external/D3DMetal.framework/D3DMetal",
            "external/D3DMetal.framework/Resources/Info.plist",
            "external/D3DMetal.framework/Resources/default.metallib",
            "external/D3DMetal.framework/Resources/libdxccontainer.dylib",
            "external/D3DMetal.framework/Resources/libdxcompiler.dylib",
            "external/D3DMetal.framework/Resources/libdxilconv.dylib",
            "external/D3DMetal.framework/Resources/libmetalirconverter.dylib",
            "wine/x86_64-unix/d3d10.so",
            "wine/x86_64-unix/d3d11.so",
            "wine/x86_64-unix/d3d12.so",
            "wine/x86_64-unix/dxgi.so",
            "wine/x86_64-unix/nvapi.so",
            "wine/x86_64-unix/nvapi64.so",
            "wine/x86_64-unix/nvngx-on-metalfx.so",
            "wine/x86_64-windows/d3d10.dll",
            "wine/x86_64-windows/d3d11.dll",
            "wine/x86_64-windows/d3d12.dll",
            "wine/x86_64-windows/dxgi.dll",
            "wine/x86_64-windows/nvapi.dll",
            "wine/x86_64-windows/nvapi64.dll",
            "wine/x86_64-windows/nvngx-on-metalfx.dll"
        ], at: renderer)
        try Data(
            contentsOf: renderer.appending(
                path: D3DMetalNVAPIAliasContract.sourceWindowsModuleRelativePath
            )
        ).write(
            to: renderer.appending(
                path: D3DMetalNVAPIAliasContract.windowsAliasRelativePath
            )
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
            <string>4.0</string>
        </dict>
        </plist>
        """.write(
            to: renderer.appending(
                path: "external/D3DMetal.framework/Resources/Info.plist"
            ),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeManagedD3DMetalRenderer(for prefix: URL) throws {
        let components = prefix.standardizedFileURL.pathComponents
        guard let prefixesIndex = components.lastIndex(of: "Prefixes"),
              prefixesIndex > 0 else {
            throw CocoaError(.fileNoSuchFile)
        }
        let managedRoot = URL(
            fileURLWithPath: NSString.path(
                withComponents: Array(components[..<prefixesIndex])
            ),
            isDirectory: true
        )
        try makeCompleteD3DMetalRenderer(
            at: ForgePlaySupplementalRendererPolicy.rendererRoot(
                forManagedRoot: managedRoot
            )
        )
    }

    private func canonicalizeD3DMetalFramework(at renderer: URL) throws {
        let framework = renderer.appending(
            path: "external/D3DMetal.framework",
            directoryHint: .isDirectory
        )
        let versionA = framework.appending(path: "Versions/A", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: versionA, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: framework.appending(path: "D3DMetal"),
            to: versionA.appending(path: "D3DMetal")
        )
        try FileManager.default.moveItem(
            at: framework.appending(path: "Resources", directoryHint: .isDirectory),
            to: versionA.appending(path: "Resources", directoryHint: .isDirectory)
        )
        try FileManager.default.createSymbolicLink(
            atPath: framework.appending(path: "Versions/Current").path,
            withDestinationPath: "A"
        )
        try FileManager.default.createSymbolicLink(
            atPath: framework.appending(path: "D3DMetal").path,
            withDestinationPath: "Versions/Current/D3DMetal"
        )
        try FileManager.default.createSymbolicLink(
            atPath: framework.appending(path: "Resources").path,
            withDestinationPath: "Versions/Current/Resources"
        )
    }

    private func makeCompleteD9VKRenderer(at renderer: URL) throws {
        try writeRendererFixture([
            "wine/i386-windows/d3d9.dll",
            "wine/x86_64-windows/d3d9.dll"
        ], at: renderer)
    }

    private func makeCompleteDXMTRenderer(at renderer: URL) throws {
        try writeRendererFixture([
            "wine/i386-windows/d3d10core.dll",
            "wine/i386-windows/d3d11.dll",
            "wine/i386-windows/dxgi.dll",
            "wine/i386-windows/winemetal.dll",
            "wine/x86_64-unix/winemetal.so",
            "wine/x86_64-windows/d3d10core.dll",
            "wine/x86_64-windows/d3d11.dll",
            "wine/x86_64-windows/dxgi.dll",
            "wine/x86_64-windows/winemetal.dll"
        ], at: renderer)
    }

    private func makeCompleteDXVKRenderer(at renderer: URL) throws {
        try writeRendererFixture([
            "wine/i386-windows/d3d8.dll",
            "wine/i386-windows/d3d9.dll",
            "wine/i386-windows/d3d10core.dll",
            "wine/i386-windows/d3d11.dll",
            "wine/i386-windows/dxgi.dll",
            "wine/x86_64-windows/d3d8.dll",
            "wine/x86_64-windows/d3d9.dll",
            "wine/x86_64-windows/d3d10core.dll",
            "wine/x86_64-windows/d3d11.dll",
            "wine/x86_64-windows/dxgi.dll"
        ], at: renderer)
    }

    private func writeRendererFixture(_ relativePaths: [String], at renderer: URL) throws {
        let sharedUnixModulePaths = Set(D3DMetalRendererPayloadContract.sharedUnixModuleRelativePaths)
        for relativePath in relativePaths where !sharedUnixModulePaths.contains(relativePath) {
            let file = renderer.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("renderer fixture".utf8).write(to: file)
        }
        let requestedSharedUnixModulePaths = relativePaths.filter(sharedUnixModulePaths.contains)
        guard !requestedSharedUnixModulePaths.isEmpty else { return }

        let sharedLibrary = renderer.appending(
            path: D3DMetalRendererPayloadContract.sharedLibraryRelativePath
        )
        if !FileManager.default.fileExists(atPath: sharedLibrary.path) {
            try FileManager.default.createDirectory(
                at: sharedLibrary.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("renderer fixture".utf8).write(to: sharedLibrary)
        }
        for relativePath in requestedSharedUnixModulePaths {
            let link = renderer.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: link.path) ||
                (try? link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try FileManager.default.removeItem(at: link)
            }
            try FileManager.default.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: D3DMetalRendererPayloadContract.sharedUnixModuleLinkTarget
            )
        }
    }

    private func makeMarkerLauncher(in root: URL, marker: URL) throws -> URL {
        let launcher = root.appending(path: "marker-wine-\(UUID().uuidString)")
        try """
        #!/bin/sh
        touch "\(marker.path)"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        return launcher
    }

    /// Managed-process journal tests and launch-path integration fixtures use
    /// the same loader layout as the packaged Runtime. Command-only fixtures
    /// opt out of that unrelated subsystem at their runner construction site.
    @discardableResult
    private func installManagedWineLoaderFixture(
        for launcher: URL
    ) throws -> URL {
        let binDirectory = launcher.deletingLastPathComponent()
        guard binDirectory.lastPathComponent == "bin" else {
            throw CocoaError(.fileNoSuchFile)
        }
        let wineLoader = binDirectory.appending(path: "wine.bin")
        try "#!/bin/sh\nexit 0\n".write(
            to: wineLoader,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: wineLoader.path
        )
        return wineLoader
    }

    private static let completeDXVKModulePaths = [
        "wine/i386-windows/d3d9.dll",
        "wine/i386-windows/d3d11.dll",
        "wine/i386-windows/dxgi.dll",
        "wine/x86_64-windows/d3d9.dll",
        "wine/x86_64-windows/d3d11.dll",
        "wine/x86_64-windows/dxgi.dll"
    ]

    private static let completeDXMTModulePaths = [
        "wine/i386-windows/d3d10core.dll",
        "wine/i386-windows/d3d11.dll",
        "wine/i386-windows/dxgi.dll",
        "wine/i386-windows/winemetal.dll",
        "wine/x86_64-unix/winemetal.so",
        "wine/x86_64-windows/d3d11.dll",
        "wine/x86_64-windows/dxgi.dll",
        "wine/x86_64-windows/winemetal.dll"
    ]

    private func makeRendererRoutingFixture(
        _ label: String
    ) throws -> (root: URL, launcher: URL, prefix: URL, rendererRoot: URL) {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayRendererRouting-\(label)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let launcher = root.appending(path: "ForgePlayRuntime/wine/bin/wine")
        let prefix = root.appending(path: "Prefix", directoryHint: .isDirectory)
        let rendererRoot = root.appending(
            path: "ForgePlayRuntime/Frameworks/renderer",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        try installManagedWineLoaderFixture(for: launcher)
        return (root, launcher, prefix, rendererRoot)
    }

    private func writeRendererComponent(
        _ component: String,
        relativePaths: [String],
        under rendererRoot: URL
    ) throws {
        for relativePath in relativePaths {
            let file = rendererRoot.appending(path: component).appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("renderer fixture".utf8).write(to: file)
        }
    }

    private struct ManagedChildExternalGrantLaunchFixture {
        let root: URL
        let launcher: URL
        let prefix: URL
        let steamExecutable: URL
        let externalRoot: URL
        let logs: URL
        let launchMarker: URL
        let compatibilitySelection: SteamPrelaunchCompatibilitySelection
    }

    private func makeManagedChildExternalGrantLaunchFixture(
        label: String
    ) throws -> ManagedChildExternalGrantLaunchFixture {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlay\(label)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let launcher = root.appending(
            path: "ForgePlayRuntime/wine/bin/wine"
        )
        let prefix = root.appending(
            path: "Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let steamDirectory = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        let steamExecutable = steamDirectory.appending(path: "steam.exe")
        let externalRoot = root.appending(
            path: "ExternalLibrary/steamapps/common/HELLDIVERS 2",
            directoryHint: .isDirectory
        ).standardizedFileURL
        let logs = root.appending(
            path: "Logs",
            directoryHint: .isDirectory
        )
        let launchMarker = root.appending(path: "launcher-started")
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: steamDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try Data("steam".utf8).write(to: steamExecutable)
        try makeCompleteD3DMetalRenderer(
            at: root.appending(
                path: "ForgePlayRuntime/Frameworks/renderer/d3dmetal",
                directoryHint: .isDirectory
            )
        )
        try """
        #!/bin/sh
        printf 'launched=1\\n' > "\(launchMarker.path)"
        printf 'grant_file=%s\\n' "$FORGEPLAY_EXTERNAL_STORAGE_GRANT_FILE"
        printf 'grant_sha=%s\\n' "$FORGEPLAY_EXTERNAL_STORAGE_GRANT_SHA256"
        printf 'grant_run=%s\\n' "$FORGEPLAY_EXTERNAL_STORAGE_GRANT_RUN_ID"
        printf 'grant_bridge=%s\\n' "$FORGEPLAY_EXTERNAL_STORAGE_BRIDGE"
        """.write(
            to: launcher,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )

        var status = stat()
        guard Darwin.lstat(externalRoot.path, &status) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let anchoredIdentity = CompatibilityAnchoredPathIdentityV1(
            entries: [
                .init(
                    path: externalRoot.path,
                    kind: .directory,
                    device: UInt64(status.st_dev),
                    inode: UInt64(status.st_ino)
                )
            ]
        )
        let managedChildPolicy = try SteamManagedWineChildCompatibilityPolicy(
            steamAppID: SteamManagedWineChildCompatibilityPolicy
                .helldivers2SteamAppID,
            canonicalGameRoot: externalRoot,
            canonicalGameRootIdentityDigest: String(repeating: "a", count: 64),
            anchoredLibraryPathIdentity: anchoredIdentity,
            manifestRootAuthorizationDigest: String(
                repeating: "b",
                count: 64
            ),
            lineageNonce: UUID(),
            heapZeroMemoryEnabled: true,
            excludesGameGuardRenderer: true
        )
        return ManagedChildExternalGrantLaunchFixture(
            root: root,
            launcher: launcher,
            prefix: prefix,
            steamExecutable: steamExecutable,
            externalRoot: externalRoot,
            logs: logs,
            launchMarker: launchMarker,
            compatibilitySelection: SteamPrelaunchCompatibilitySelection(
                rendererSelection: .d3dMetal,
                networkSelection: .standard,
                audioInputSelection: .enabled,
                managedWineChildPolicy: managedChildPolicy
            )
        )
    }

    /// Process-boundary tests use a synthetic stand-in for the already-curated
    /// app-bundled runtime. Runtime identity rejection belongs to
    /// WindowsRuntimeServiceTests; these tests exercise the command runner after
    /// that boundary has accepted the executable.
    private func makeCuratedRuntimeRunner(
        sandboxEnabled: Bool = false,
        managedWineProcessJournalEnabled: Bool = true,
        externalStorageGrantPublisher:
            SafeProcessRunner.ExternalStorageGrantPublisher? = nil,
        gameModeHostApplicationGroupIdentifier: String? = nil,
        gameModeHostApplicationGroupContainerResolver:
            SafeProcessRunner
                .GameModeHostApplicationGroupContainerResolver? = nil,
        managedWineSessionRegistry: ManagedWineSessionRegistry =
            ManagedWineSessionRegistry(),
        runtimeLaunchObjectIdentityProvider:
            @escaping SafeProcessRunner.RuntimeLaunchObjectIdentityProvider = {
                _ in nil
            },
        managedWineChildSynchronizationReadbackProvider:
            SafeProcessRunner
                .ManagedWineChildSynchronizationReadbackProvider? = nil
    ) -> SafeProcessRunner {
        let gameModeSelectionResolver:
            SafeProcessRunner.GameModeSteamChildSelectionResolver = {
                runtimeExecutable,
                prefix,
                evidenceLogURL,
                runIdentifier in
                let hostExecutable = runtimeExecutable
                    .deletingLastPathComponent()
                    .appending(path: "GameModeProcessHost")
                return GameModeSteamChildHostSelection(
                    host: GameModeHostCapability(
                        appURL: hostExecutable
                            .deletingLastPathComponent()
                            .appending(path: "GameModeProcessHost.app"),
                        executableURL: hostExecutable,
                        bundleIdentifier: "com.forgeplay.tests.game-mode-host",
                        executableSHA256: String(repeating: "b", count: 64),
                        supportsGameMode: true,
                        isRosettaRuntimeComponent: true
                    ),
                    runtimeNtdllURL: runtimeExecutable
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .appending(path: "lib/wine/x86_64-unix/ntdll.so"),
                    prefixExecutionLockURL: prefix.appending(
                        path: ".forgeplay-prefix-execution.lock"
                    ),
                    evidenceLogURL: evidenceLogURL,
                    runIdentifier: runIdentifier.lowercased()
                )
            }
        if let externalStorageGrantPublisher {
            return SafeProcessRunner(
                sandboxEnabled: sandboxEnabled,
                managedWineProcessJournalEnabled:
                    managedWineProcessJournalEnabled,
                managedWineProcessEvidenceSandboxEnabled: false,
                managedWineSessionRegistry: managedWineSessionRegistry,
                externalStorageGrantPublisher:
                    externalStorageGrantPublisher,
                gameModeHostApplicationGroupIdentifier:
                    gameModeHostApplicationGroupIdentifier ??
                        ForgePlaySandboxPolicy
                            .primaryApplicationGroupIdentifier,
                gameModeHostApplicationGroupContainerResolver:
                    gameModeHostApplicationGroupContainerResolver,
                gameModeSteamChildSelectionResolver:
                    gameModeSelectionResolver,
                managedWineRuntimeFingerprintResolver: {
                    _ in String(repeating: "a", count: 64)
                },
                runtimeLaunchObjectIdentityProvider:
                    runtimeLaunchObjectIdentityProvider,
                managedWineChildSynchronizationReadbackProvider:
                    managedWineChildSynchronizationReadbackProvider,
                windowsRuntimeValidator: { _, _ in },
                supplementalRendererAuthenticator:
                    SafeProcessRunnerTestSupplementalRendererAuthenticator()
            )
        }
        return SafeProcessRunner(
            sandboxEnabled: sandboxEnabled,
            managedWineProcessJournalEnabled:
                managedWineProcessJournalEnabled,
            managedWineProcessEvidenceSandboxEnabled: false,
            managedWineSessionRegistry: managedWineSessionRegistry,
            gameModeHostApplicationGroupIdentifier:
                gameModeHostApplicationGroupIdentifier ??
                    ForgePlaySandboxPolicy.primaryApplicationGroupIdentifier,
            gameModeHostApplicationGroupContainerResolver:
                gameModeHostApplicationGroupContainerResolver,
            gameModeSteamChildSelectionResolver:
                gameModeSelectionResolver,
            managedWineRuntimeFingerprintResolver: {
                _ in String(repeating: "a", count: 64)
            },
            runtimeLaunchObjectIdentityProvider:
                runtimeLaunchObjectIdentityProvider,
            managedWineChildSynchronizationReadbackProvider:
                managedWineChildSynchronizationReadbackProvider,
            windowsRuntimeValidator: { _, _ in },
            supplementalRendererAuthenticator:
                SafeProcessRunnerTestSupplementalRendererAuthenticator()
        )
    }

    private struct ManagedWineDescriptorFixture {
        let root: URL
        let prefix: URL
        let runtimeRoot: URL
        let evidenceDirectory: URL
        let evidenceURL: URL
        let descriptorURL: URL
        let runIdentifier: String
        let runtimeFingerprint: String
    }

    private func makeManagedWineDescriptorFixture(
        ownerProcessIdentifier: pid_t = Darwin.getpid(),
        ownerProcessStartedAt: UInt64? = nil
    ) throws -> ManagedWineDescriptorFixture {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayManagedWineDescriptor-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let prefix = root.appending(
            path: "ManagedData/Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let runtimeRoot = root.appending(
            path: "Runtime/ForgePlayRuntime/wine",
            directoryHint: .isDirectory
        )
        let evidenceDirectory = root.appending(
            path: "Group/ManagedWineProcessEvidence",
            directoryHint: .isDirectory
        )
        for directory in [prefix, runtimeRoot, evidenceDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: evidenceDirectory.path
        )
        let runIdentifier = UUID().uuidString.lowercased()
        let runtimeFingerprint = String(repeating: "a", count: 64)
        let evidenceURL = evidenceDirectory.appending(
            path: ManagedWineProcessJournal.evidenceFileName(
                runIdentifier: runIdentifier
            )
        )
        try Data().write(to: evidenceURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: evidenceURL.path
        )
        let startedAt = try XCTUnwrap(
            ownerProcessStartedAt ?? ManagedWineProcessJournal
                .processStartTimeUnixMicroseconds(
                    for: ownerProcessIdentifier
                )
        )
        let descriptor = try ManagedWineProcessJournal
            .makeActiveSessionDescriptor(
                runIdentifier: runIdentifier,
                evidenceURL: evidenceURL,
                prefix: prefix,
                runtimeRootURL: runtimeRoot,
                runtimeFingerprint: runtimeFingerprint,
                ownerProcessIdentifier: ownerProcessIdentifier,
                ownerProcessStartedAtUnixMicroseconds: startedAt,
                registeredAt: Date()
            )
        let descriptorURL = try ManagedWineProcessJournal
            .writeActiveSessionDescriptor(
                descriptor,
                in: evidenceDirectory
            )
        return ManagedWineDescriptorFixture(
            root: root,
            prefix: prefix,
            runtimeRoot: runtimeRoot,
            evidenceDirectory: evidenceDirectory,
            evidenceURL: evidenceURL,
            descriptorURL: descriptorURL,
            runIdentifier: runIdentifier,
            runtimeFingerprint: runtimeFingerprint
        )
    }

    private var managedProcessFixtureScript: String {
        """
        #!/bin/sh
        trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 0' TERM INT
        sleep 60 &
        child=$!
        wait "$child"
        """
    }

    private func adHocSignExecutable(_ executable: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", executable.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "SafeProcessRunnerTests.AdHocSigning",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Could not ad-hoc sign process fixture: \(executable.path)"]
            )
        }
    }

    private func makeWineRunner(in root: URL, wineserverScript: String) throws -> URL {
        let bin = root.appending(path: "FakeRuntime/wine/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let launcher = bin.appending(path: "wine")
        let wineserver = bin.appending(path: "wineserver")
        try "#!/bin/sh\nexit 0\n".write(to: launcher, atomically: true, encoding: .utf8)
        try wineserverScript.write(to: wineserver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserver.path)
        return launcher
    }
}
