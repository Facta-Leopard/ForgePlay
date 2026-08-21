import XCTest
@testable import ForgePlay

@MainActor
final class AutoFixServiceTests: XCTestCase {
    func testAutoFixWindowsVersionMessageUsesLocalizationFormatKey() throws {
        let root = projectRoot()
        let source = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/Services/AutoFixService.swift"),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: root.appending(path: "Sources/ForgePlay/UI/LocalizedActionPresentation.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(#"message: "Windows 설정을 %@로 기록했습니다.""#))
        XCTAssertFalse(source.contains(#"message: "Windows 설정을 \(version)로 기록했습니다.""#))
        XCTAssertTrue(presentation.contains(#"appState.localizedFormat("Windows 설정을 %@로 기록했습니다.", version)"#))
    }

    func testApplyNormalizesUnsafeLaunchOptionBeforeMutatingPrefix() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayAutoFixTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runner = SafeProcessRunner()
        let prefixManager = PrefixManager(pathManager: pathManager, runner: runner)
        let runtimeManager = RuntimeManager(pathManager: pathManager, runner: runner)
        let windowsRuntimeService = WindowsRuntimeService(pathManager: pathManager, runner: runner)
        let service = AutoFixService(
            prefixManager: prefixManager,
            runtimeManager: runtimeManager,
            steamPrefixService: makeSteamPrefixService(
                prefixManager: prefixManager,
                windowsRuntimeService: windowsRuntimeService,
                pathManager: pathManager,
                runner: runner
            )
        )
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let unsafeAction = RecommendedAction(
            type: .addLaunchOption,
            runtime: nil,
            windowsVersion: nil,
            dll: nil,
            override: nil,
            launchOption: "; rm -rf /",
            requiresUserConfirmation: true,
            riskLevel: .medium,
            reason: "Unsafe stored action"
        )

        let result = try await service.apply(
            action: unsafeAction,
            prefixURL: prefixURL,
            runtimeExecutable: nil
        )
        let reloaded = try prefixManager.loadMetadata(at: prefixURL)

        XCTAssertEqual(result.action.type, .noAction)
        XCTAssertTrue(reloaded.launchOptions.isEmpty)
    }

    func testApplyRejectsActionsWithoutImplementedPostconditions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayAutoFixUnsupported-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runner = SafeProcessRunner()
        let prefixManager = PrefixManager(pathManager: pathManager, runner: runner)
        let service = AutoFixService(
            prefixManager: prefixManager,
            runtimeManager: RuntimeManager(pathManager: pathManager, runner: runner),
            steamPrefixService: makeSteamPrefixService(
                prefixManager: prefixManager,
                windowsRuntimeService: WindowsRuntimeService(pathManager: pathManager, runner: runner),
                pathManager: pathManager,
                runner: runner
            )
        )
        let prefixURL = URL(fileURLWithPath: try prefixManager.createSteamSharedPrefix().path)
        let unsupportedActions = [
            RecommendedAction(
                type: .addLaunchOption,
                runtime: nil,
                windowsVersion: nil,
                dll: nil,
                override: nil,
                launchOption: "-windowed",
                requiresUserConfirmation: true,
                riskLevel: .low,
                reason: "Launch option is not connected to a game launch contract"
            ),
            RecommendedAction(
                type: .markUnsupported,
                runtime: nil,
                windowsVersion: nil,
                dll: nil,
                override: nil,
                launchOption: nil,
                requiresUserConfirmation: true,
                riskLevel: .high,
                reason: "No game record is associated with this diagnostic"
            )
        ]

        for action in unsupportedActions {
            do {
                _ = try await service.apply(
                    action: action,
                    prefixURL: prefixURL,
                    runtimeExecutable: nil
                )
                XCTFail("Expected \(action.type.rawValue) to be rejected")
            } catch AutoFixServiceError.unsupportedAction {
                // Expected until the action has a verifiable game-specific postcondition.
            } catch {
                XCTFail("Unexpected error for \(action.type.rawValue): \(error)")
            }
        }
    }

    func testApplyDoesNotDefaultMissingDLLOverride() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayAutoFixTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runner = SafeProcessRunner()
        let prefixManager = PrefixManager(pathManager: pathManager, runner: runner)
        let runtimeManager = RuntimeManager(pathManager: pathManager, runner: runner)
        let windowsRuntimeService = WindowsRuntimeService(pathManager: pathManager, runner: runner)
        let service = AutoFixService(
            prefixManager: prefixManager,
            runtimeManager: runtimeManager,
            steamPrefixService: makeSteamPrefixService(
                prefixManager: prefixManager,
                windowsRuntimeService: windowsRuntimeService,
                pathManager: pathManager,
                runner: runner
            )
        )
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let action = RecommendedAction(
            type: .setDLLOverride,
            runtime: nil,
            windowsVersion: nil,
            dll: "d3dcompiler_47",
            override: nil,
            launchOption: nil,
            requiresUserConfirmation: true,
            riskLevel: .low,
            reason: "Incomplete DLL override"
        )

        let result = try await service.apply(
            action: action,
            prefixURL: prefixURL,
            runtimeExecutable: nil
        )

        XCTAssertEqual(result.action.type, .noAction)
        let reloaded = try prefixManager.loadMetadata(at: prefixURL)
        XCTAssertTrue(reloaded.dllOverrides.isEmpty)
    }

    func testApplyInstallRuntimeRejectsUnsafePrefixBeforeSnapshotAndRunner() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayAutoFixTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalRegistry = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayAutoFixExternalRegistry-\(UUID().uuidString).reg")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalRegistry)
        }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runner = SafeProcessRunner()
        let prefixManager = PrefixManager(pathManager: pathManager, runner: runner)
        let runtimeManager = RuntimeManager(pathManager: pathManager, runner: runner)
        let windowsRuntimeService = WindowsRuntimeService(pathManager: pathManager, runner: runner)
        let service = AutoFixService(
            prefixManager: prefixManager,
            runtimeManager: runtimeManager,
            steamPrefixService: makeSteamPrefixService(
                prefixManager: prefixManager,
                windowsRuntimeService: windowsRuntimeService,
                pathManager: pathManager,
                runner: runner
            )
        )
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)
        let systemRegistry = prefixURL.appending(path: "system.reg")
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "dosdevices/c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win64\n".write(to: externalRegistry, atomically: true, encoding: .utf8)
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(at: systemRegistry, withDestinationURL: externalRegistry)

        let installer = root.appending(path: "vc_redist.x64.exe")
        try "installer fixture".write(to: installer, atomically: true, encoding: .utf8)
        let marker = root.appending(path: "autofix-runtime-runner-called")
        let launcher = try makeMarkerLauncher(in: root, marker: marker)
        let action = RecommendedAction(
            type: .installRuntime,
            runtime: .vcrun2022,
            windowsVersion: nil,
            dll: nil,
            override: nil,
            launchOption: nil,
            requiresUserConfirmation: true,
            riskLevel: .medium,
            reason: "Install runtime"
        )

        do {
            _ = try await service.apply(
                action: action,
                prefixURL: prefixURL,
                runtimeExecutable: launcher,
                installerURL: installer
            )
            XCTFail("Expected unsafe prefix to reject runtime AutoFix")
        } catch PrefixUsabilityError.unsafeRequiredItem(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, systemRegistry.standardizedFileURL.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let snapshots = try FileManager.default.contentsOfDirectory(
            at: try pathManager.url(for: .prefixSnapshots),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testApplyRejectsPrefixMutationOwnedByAnotherForgePlayProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayAutoFixOwnership-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let runner = SafeProcessRunner()
        let lifecycleCoordinator = SteamPrefixLifecycleCoordinator()
        let prefixManager = PrefixManager(
            pathManager: pathManager,
            runner: runner,
            lifecycleCoordinator: lifecycleCoordinator
        )
        let windowsRuntimeService = WindowsRuntimeService(pathManager: pathManager, runner: runner)
        let steamPrefixService = SteamPrefixService(
            windowsRuntimeService: windowsRuntimeService,
            prefixManager: prefixManager,
            steamManager: SteamManager(pathManager: pathManager, runner: runner),
            lifecycleCoordinator: lifecycleCoordinator
        )
        let service = AutoFixService(
            prefixManager: prefixManager,
            runtimeManager: RuntimeManager(pathManager: pathManager, runner: runner),
            steamPrefixService: steamPrefixService
        )
        let externalOwnership = try ManagedRootOperationLease.acquireRuntimeOwnership(
            forManagedRoot: root
        )
        defer { externalOwnership.release() }
        let action = RecommendedAction(
            type: .setWindowsVersion,
            runtime: nil,
            windowsVersion: "win10",
            dll: nil,
            override: nil,
            launchOption: nil,
            requiresUserConfirmation: true,
            riskLevel: .medium,
            reason: "Update Windows version"
        )

        do {
            _ = try await service.apply(
                action: action,
                prefixURL: root.appending(path: "Prefixes/SteamShared", directoryHint: .isDirectory),
                runtimeExecutable: root.appending(path: "wine", directoryHint: .notDirectory)
            )
            XCTFail("Expected AutoFix to reject a managed root owned by another process")
        } catch let error as SteamPrefixLifecycleError {
            XCTAssertEqual(error, .operationInProgress)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeSteamPrefixService(
        prefixManager: PrefixManager,
        windowsRuntimeService: WindowsRuntimeService,
        pathManager: PathManager,
        runner: SafeProcessRunner
    ) -> SteamPrefixService {
        SteamPrefixService(
            windowsRuntimeService: windowsRuntimeService,
            prefixManager: prefixManager,
            steamManager: SteamManager(pathManager: pathManager, runner: runner)
        )
    }

    private func makeMarkerLauncher(in root: URL, marker: URL) throws -> URL {
        let launcher = root.appending(path: "marker-wine64-\(UUID().uuidString)")
        try """
        #!/bin/sh
        touch "\(marker.path)"
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        return launcher
    }

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
