import Foundation
import XCTest
@testable import ForgePlay

private final class RuntimeCapabilityInspectionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var countStorage = 0
    private var inspectedOnMainThreadStorage = false

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return countStorage
    }

    var inspectedOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inspectedOnMainThreadStorage
    }

    func recordInspection() {
        lock.lock()
        countStorage += 1
        inspectedOnMainThreadStorage =
            inspectedOnMainThreadStorage || Thread.isMainThread
        lock.unlock()
    }
}

@MainActor
final class SystemCheckServiceTests: XCTestCase {
    private let fileManager = FileManager.default

    func testStorageCheckRejectsUnsafeManagedRootEvenWhenWritable() async throws {
        let root = temporaryDirectory("UnsafeRoot")
        let externalLogs = temporaryDirectory("ExternalLogs")
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: externalLogs)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: externalLogs, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: root.appending(path: ForgePlayPathRole.logs.rawValue, directoryHint: .isDirectory),
            withDestinationURL: externalLogs
        )

        let service = try makeSystemCheckService(
            managedRoot: nil,
            bundledExecutable: nil,
            canRunBundledRuntime: false
        )
        let checks = await service.runChecks(rootURL: root, runtimeExecutable: nil)
        let storageCheck = try XCTUnwrap(checks.first { $0.title == "저장 위치" })

        XCTAssertEqual(storageCheck.status, .error)
        XCTAssertTrue(storageCheck.detail.contains("쓸 수 없습니다"))
        XCTAssertTrue(storageCheck.technicalDetail?.contains("PathManagerError") == true)
        XCTAssertNil(storageCheck.technicalDetail?.range(of: "[가-힣]", options: .regularExpression))
    }

    func testRosettaGateBlocksBundledRuntimeProbeWhenTranslationIsNotDetected() async throws {
        let root = temporaryDirectory("RosettaGate")
        defer { try? fileManager.removeItem(at: root) }
        let executable = root.appending(path: "BundledResources/Runners/ForgePlayRuntime/wine/bin/wine")
        try writeExecutable(at: executable, exitCode: 0)
        let service = try makeSystemCheckService(
            managedRoot: root.appending(path: "Managed"),
            bundledExecutable: executable,
            canRunBundledRuntime: true,
            translationAvailability: "notDetected"
        )

        let checks = await service.runChecks(rootURL: root.appending(path: "Managed"), runtimeExecutable: executable)
        let runtimeCheck = try XCTUnwrap(checks.first { $0.title == "ForgePlay Runtime" })

        XCTAssertEqual(runtimeCheck.status, .error)
        XCTAssertTrue(runtimeCheck.detail.contains("Rosetta"))
        XCTAssertEqual(runtimeCheck.technicalDetail, "rosetta-translation-not-detected")
    }

    func testUnavailableBundledRuntimeIsAnErrorRatherThanAnExternalSelectionPrompt() async throws {
        let root = temporaryDirectory("UnavailableRuntime")
        defer { try? fileManager.removeItem(at: root) }
        let executable = root.appending(path: "Candidate/wine")
        try writeExecutable(at: executable, exitCode: 0)
        let unavailableReason = "bundled runtime fixture unavailable"
        let service = try makeSystemCheckService(
            managedRoot: root.appending(path: "Managed"),
            bundledExecutable: nil,
            canRunBundledRuntime: false,
            unavailableReason: unavailableReason
        )

        let checks = await service.runChecks(rootURL: root.appending(path: "Managed"), runtimeExecutable: executable)
        let runtimeCheck = try XCTUnwrap(checks.first { $0.title == "ForgePlay Runtime" })

        XCTAssertEqual(runtimeCheck.status, .error)
        XCTAssertEqual(runtimeCheck.detail, unavailableReason)
        XCTAssertEqual(runtimeCheck.technicalDetail, "bundled-runtime-unavailable")
    }

    func testMissingBundledRuntimeIsReportedWithoutOfferingExternalRuntimeDiscovery() async throws {
        let root = temporaryDirectory("MissingRuntime")
        defer { try? fileManager.removeItem(at: root) }
        let unavailableReason = "bundled runtime fixture unavailable"
        let service = try makeSystemCheckService(
            managedRoot: root,
            bundledExecutable: nil,
            canRunBundledRuntime: false,
            unavailableReason: unavailableReason
        )

        let checks = await service.runChecks(rootURL: root, runtimeExecutable: nil)
        let runtimeCheck = try XCTUnwrap(checks.first { $0.title == "ForgePlay Runtime" })

        XCTAssertEqual(runtimeCheck.status, .error)
        XCTAssertEqual(runtimeCheck.detail, unavailableReason)
        XCTAssertEqual(runtimeCheck.technicalDetail, "windows-runner-unavailable-in-current-build")
    }

    func testRuntimeCheckRejectsExecutableOutsideExactBundledBoundary() async throws {
        let root = temporaryDirectory("ExactBoundary")
        defer { try? fileManager.removeItem(at: root) }
        let bundled = root.appending(path: "BundledResources/Runners/ForgePlayRuntime/wine/bin/wine")
        let external = root.appending(path: "External/wine")
        try writeExecutable(at: bundled, exitCode: 0)
        try writeExecutable(at: external, exitCode: 0)
        let service = try makeSystemCheckService(
            managedRoot: root.appending(path: "Managed"),
            bundledExecutable: bundled,
            canRunBundledRuntime: true
        )

        let checks = await service.runChecks(rootURL: root.appending(path: "Managed"), runtimeExecutable: external)
        let runtimeCheck = try XCTUnwrap(checks.first { $0.title == "ForgePlay Runtime" })

        XCTAssertEqual(runtimeCheck.status, .error)
        XCTAssertTrue(runtimeCheck.detail.contains("손상되었거나"))
        XCTAssertTrue(runtimeCheck.technicalDetail?.contains("앱에 포함된 ForgePlay Runtime만 실행 엔진") == true)
    }

    func testRuntimeProbeFailureUsesRuntimeProbeEvidence() async throws {
        let root = temporaryDirectory("ProbeFailure")
        defer { try? fileManager.removeItem(at: root) }
        let managedRoot = root.appending(path: "Managed")
        let executable = root.appending(path: "BundledResources/Runners/ForgePlayRuntime/wine/bin/wine")
        try writeExecutable(at: executable, exitCode: 86)
        let service = try makeSystemCheckService(
            managedRoot: managedRoot,
            bundledExecutable: executable,
            canRunBundledRuntime: true
        )

        let checks = await service.runChecks(rootURL: managedRoot, runtimeExecutable: executable)
        let runtimeCheck = try XCTUnwrap(checks.first { $0.title == "ForgePlay Runtime" })

        XCTAssertEqual(runtimeCheck.status, .error)
        XCTAssertTrue(runtimeCheck.detail.contains("실행할 수 없습니다"))
        XCTAssertTrue(runtimeCheck.technicalDetail?.contains("runtime_probe") == true)
    }

    func testAuthenticatedRuntimeCapabilitySnapshotRunsOffMainAndReusesIdentity()
        async throws {
        let root = temporaryDirectory("RuntimeCapabilitySnapshot")
        defer { try? fileManager.removeItem(at: root) }
        let managedRoot = root.appending(path: "Managed", directoryHint: .isDirectory)
        let executable = root.appending(
            path: "BundledResources/Runners/ForgePlayRuntime/wine/bin/wine"
        )
        try writeExecutable(at: executable, exitCode: 0)
        let manifest = runtimeManifest(seed: "snapshot")
        let authenticatedContext = RuntimeAuthenticatedContext(
            manifest: manifest,
            runtimeRoot: executable
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        )
        let counter = RuntimeCapabilityInspectionCounter()
        let service = try makeSystemCheckService(
            managedRoot: managedRoot,
            bundledExecutable: executable,
            canRunBundledRuntime: true,
            runtimeAuthenticationProvider: { _ in authenticatedContext },
            runtimeCapabilityProvider: { executable, _ in
                counter.recordInspection()
                return WindowsRuntimeCapability(
                    executableURL: executable,
                    graphicsBackend: .unknown,
                    evidence: [],
                    limitations: ["fixture-capability-limitation"]
                )
            },
            bypassRuntimeAuthenticationGate: false
        )

        let first = await service.runChecksWithRuntimeContext(
            rootURL: managedRoot,
            runtimeExecutable: executable
        )
        let second = await service.runChecksWithRuntimeContext(
            rootURL: managedRoot,
            runtimeExecutable: executable
        )

        XCTAssertEqual(
            first.authenticatedRuntimeManifest?.runnerBuildFingerprint,
            manifest.runnerBuildFingerprint
        )
        XCTAssertEqual(
            second.authenticatedRuntimeManifest?.runnerBuildFingerprint,
            manifest.runnerBuildFingerprint
        )
        XCTAssertEqual(
            first.runtimeCapability?.limitations,
            ["fixture-capability-limitation"]
        )
        XCTAssertEqual(
            second.runtimeCapability,
            first.runtimeCapability
        )
        XCTAssertEqual(counter.count, 1)
        XCTAssertFalse(counter.inspectedOnMainThread)

        await service.invalidateRuntimeCapabilitySnapshots()
        _ = await service.runChecksWithRuntimeContext(
            rootURL: managedRoot,
            runtimeExecutable: executable
        )
        XCTAssertEqual(counter.count, 2)
    }

    func testSteamPrefixCheckSurfacesBrokenMetadataAsError() async throws {
        let root = temporaryDirectory("BrokenPrefix")
        defer { try? fileManager.removeItem(at: root) }
        let pathManager = PathManager(fileManager: fileManager)
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        try installMinimumUsablePrefix(at: prefixURL)
        try Data("{".utf8).write(to: prefixURL.appending(path: "prefix.json"))
        let service = makeSystemCheckService(
            pathManager: pathManager,
            prefixManager: prefixManager,
            bundledExecutable: nil,
            canRunBundledRuntime: false
        )

        let checks = await service.runChecks(rootURL: root, runtimeExecutable: nil)
        let prefixCheck = try XCTUnwrap(checks.first { $0.title == "Steam 프리픽스" })

        XCTAssertEqual(prefixCheck.status, .error)
        XCTAssertTrue(prefixCheck.detail.contains("사용할 수 없습니다"))
        XCTAssertTrue(prefixCheck.technicalDetail?.contains("PrefixUsabilityError") == true)
    }

    func testSteamPrefixCheckKeepsUninitializedPrefixAsWarning() async throws {
        let root = temporaryDirectory("UninitializedPrefix")
        defer { try? fileManager.removeItem(at: root) }
        let service = try makeSystemCheckService(
            managedRoot: root,
            bundledExecutable: nil,
            canRunBundledRuntime: false
        )

        let checks = await service.runChecks(rootURL: root, runtimeExecutable: nil)
        let prefixCheck = try XCTUnwrap(checks.first { $0.title == "Steam 프리픽스" })

        XCTAssertEqual(prefixCheck.status, .warning)
        XCTAssertTrue(prefixCheck.detail.contains("아직 초기화하지 않았습니다"))
    }

    func testSystemCheckSummaryUsesOneNonBlockingWarningPolicy() {
        let unverified = SystemCheckSummary(results: [])
        XCTAssertEqual(unverified.phase, .unverified)
        XCTAssertFalse(unverified.allowsSetupProgress)
        XCTAssertEqual(unverified.displayStatus, .unknown)

        let warned = SystemCheckSummary(results: [
            SystemCheckResult(title: "Runtime", detail: "Recommendation", status: .warning)
        ])
        XCTAssertEqual(warned.phase, .readyWithWarnings)
        XCTAssertTrue(warned.allowsSetupProgress)
        XCTAssertEqual(warned.displayStatus, .warning)

        let blocked = SystemCheckSummary(results: [
            SystemCheckResult(title: "Storage", detail: "Unavailable", status: .error),
            SystemCheckResult(title: "Runtime", detail: "Recommendation", status: .warning)
        ])
        XCTAssertEqual(blocked.phase, .blocked)
        XCTAssertFalse(blocked.allowsSetupProgress)
        XCTAssertEqual(blocked.displayStatus, .error)

        let ready = SystemCheckSummary(results: [
            SystemCheckResult(title: "Storage", detail: "Ready", status: .ok)
        ])
        XCTAssertEqual(ready.phase, .ready)
        XCTAssertTrue(ready.allowsSetupProgress)
        XCTAssertEqual(ready.displayStatus, .ok)
    }

    private func temporaryDirectory(_ label: String) -> URL {
        fileManager.temporaryDirectory.appending(
            path: "ForgePlay-SystemCheckServiceTests-\(label)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func makeSystemCheckService(
        managedRoot: URL?,
        bundledExecutable: URL?,
        canRunBundledRuntime: Bool,
        unavailableReason: String = "bundled runtime unavailable",
        translationAvailability: String = "available",
        runtimeAuthenticationProvider:
            SystemCheckService.RuntimeAuthenticationProvider? = nil,
        runtimeCapabilityProvider:
            (@Sendable (URL, URL?) throws ->
                WindowsRuntimeCapability)? = nil,
        bypassRuntimeAuthenticationGate: Bool = true
    ) throws -> SystemCheckService {
        let pathManager = PathManager(fileManager: fileManager)
        if let managedRoot {
            try pathManager.configureRoot(managedRoot)
        }
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        return makeSystemCheckService(
            pathManager: pathManager,
            prefixManager: prefixManager,
            bundledExecutable: bundledExecutable,
            canRunBundledRuntime: canRunBundledRuntime,
            unavailableReason: unavailableReason,
            translationAvailability: translationAvailability,
            runtimeAuthenticationProvider: runtimeAuthenticationProvider,
            runtimeCapabilityProvider: runtimeCapabilityProvider,
            bypassRuntimeAuthenticationGate:
                bypassRuntimeAuthenticationGate
        )
    }

    private func makeSystemCheckService(
        pathManager: PathManager,
        prefixManager: PrefixManager,
        bundledExecutable: URL?,
        canRunBundledRuntime: Bool,
        unavailableReason: String = "bundled runtime unavailable",
        translationAvailability: String = "available",
        runtimeAuthenticationProvider:
            SystemCheckService.RuntimeAuthenticationProvider? = nil,
        runtimeCapabilityProvider:
            (@Sendable (URL, URL?) throws ->
                WindowsRuntimeCapability)? = nil,
        bypassRuntimeAuthenticationGate: Bool = true
    ) -> SystemCheckService {
        let expectedPath = bundledExecutable?.standardizedFileURL.path
        let runner = SafeProcessRunner(
            fileManager: FileManager(),
            sandboxEnabled: false,
            runtimeLaunchObjectIdentityProvider: { _ in nil },
            windowsRuntimeValidator: { executable, actionName in
                guard let expectedPath else {
                    throw ForgePlayRuntimeCapabilityError.bundledRuntimeUnavailable(
                        actionName: actionName
                    )
                }
                guard executable.standardizedFileURL.path == expectedPath else {
                    throw ForgePlayRuntimeCapabilityError.nonBundledRuntimeRejected(
                        actionName: actionName,
                        path: executable.path
                    )
                }
            }
        )
        let runtimeService: WindowsRuntimeService
        if let runtimeCapabilityProvider {
            let provider = WindowsRuntimeCapabilityProvider(
                inspector: runtimeCapabilityProvider
            )
            runtimeService = WindowsRuntimeService(
                pathManager: pathManager,
                runner: runner,
                fileManager: fileManager,
                bundledRuntimeExecutableProvider: { bundledExecutable },
                runtimeCapabilityProvider: provider
            )
        } else {
            runtimeService = WindowsRuntimeService(
                pathManager: pathManager,
                runner: runner,
                fileManager: fileManager,
                bundledRuntimeExecutableProvider: { bundledExecutable }
            )
        }
        return SystemCheckService(
            pathManager: pathManager,
            windowsRuntimeService: runtimeService,
            prefixManager: prefixManager,
            canRunBundledWindowsRuntime: bypassRuntimeAuthenticationGate
                ? { canRunBundledRuntime }
                : nil,
            bundledRuntimeUnavailableReasonKey: { unavailableReason },
            runtimeTranslationAvailability: { translationAvailability },
            runtimeAuthenticationProvider: runtimeAuthenticationProvider
        )
    }

    private func runtimeManifest(seed: String) -> RuntimeManifest {
        let digest = String(repeating: seed.first ?? "a", count: 64)
        return RuntimeManifest(
            schemaVersion: RuntimeManifest.currentSchemaVersion,
            runtimeIdentifier: "fixture-\(seed)",
            wineVersion: "fixture",
            architecture: WinePrefixDefaults.architecture,
            sourceTreeSHA256: digest,
            patchSetSHA256: digest,
            runnerLauncherSHA256: digest,
            wineInfSHA256: digest,
            winebootSHA256: digest,
            prefixCompatibilityFingerprint: digest,
            runnerBuildFingerprint: digest,
            corePayloadFingerprint: digest
        )
    }

    private func writeExecutable(at url: URL, exitCode: Int32) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nprintf 'runtime probe fixture\\n'\nexit \(exitCode)\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func installMinimumUsablePrefix(at prefix: URL) throws {
        try fileManager.createDirectory(
            at: prefix.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
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
    }
}
