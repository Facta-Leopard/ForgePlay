import Foundation
import XCTest
@testable import ForgePlay

private final class RuntimeCapabilityInspectionProbe: @unchecked Sendable {
    typealias Mutation = @Sendable (_ inspectionIndex: Int) throws -> Void

    private let lock = NSLock()
    private let delay: TimeInterval
    private let mutation: Mutation
    private var mutableInspectionCount = 0
    private var mutableDidInspectOnMainThread = false

    init(
        delay: TimeInterval = 0,
        mutation: @escaping Mutation = { _ in }
    ) {
        self.delay = delay
        self.mutation = mutation
    }

    func inspect(
        executable: URL,
        supplementalRendererRoot _: URL?
    ) throws -> WindowsRuntimeCapability {
        lock.lock()
        mutableInspectionCount += 1
        let inspectionIndex = mutableInspectionCount
        mutableDidInspectOnMainThread =
            mutableDidInspectOnMainThread || Thread.isMainThread
        lock.unlock()

        try mutation(inspectionIndex)
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        return WindowsRuntimeCapability(
            executableURL: executable,
            graphicsBackend: .unknown,
            evidence: ["provider-test-\(inspectionIndex)"],
            limitations: []
        )
    }

    var inspectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return mutableInspectionCount
    }

    var didInspectOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mutableDidInspectOnMainThread
    }
}

@MainActor
final class WindowsRuntimeServiceTests: XCTestCase {
    private let fileManager = FileManager.default

    func testBundledRuntimePolicyAcceptsOnlyExactCuratedExecutable() throws {
        let resourceRoot = temporaryDirectory("BundledPolicy")
        defer { try? fileManager.removeItem(at: resourceRoot) }

        let expected = resourceRoot
            .appending(path: "Runners/ForgePlayRuntime/wine/bin/wine")
        let sibling = expected.deletingLastPathComponent().appending(path: "wine64")
        let copied = resourceRoot.appending(path: "CopiedRuntime/wine")
        try writeExecutable(at: expected)
        try writeExecutable(at: sibling)
        try writeExecutable(at: copied)

        XCTAssertEqual(
            ForgePlayBundledWindowsRuntimePolicy.findBundledRuntimeExecutable(
                inResourceRoot: resourceRoot,
                fileManager: fileManager
            )?.standardizedFileURL,
            expected.standardizedFileURL
        )
        XCTAssertTrue(
            ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable(
                expected,
                inResourceRoot: resourceRoot,
                fileManager: fileManager
            )
        )
        XCTAssertFalse(
            ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable(
                sibling,
                inResourceRoot: resourceRoot,
                fileManager: fileManager
            )
        )
        XCTAssertFalse(
            ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable(
                copied,
                inResourceRoot: resourceRoot,
                fileManager: fileManager
            )
        )
    }

    func testServiceValidationRejectsExternalExecutableEvenWhenItIsNamedWine() throws {
        let sandbox = temporaryDirectory("ValidationBoundary")
        defer { try? fileManager.removeItem(at: sandbox) }

        let fixture = try makeRuntimeFixture(under: sandbox.appending(path: "Bundled"))
        let external = sandbox.appending(path: "External/wine")
        try writeExecutable(at: external)
        let service = try makeService(
            managedRoot: sandbox.appending(path: "Managed"),
            bundledExecutable: fixture.executable
        )

        let bundledValidation = service.validateExecutable(fixture.executable)
        XCTAssertTrue(bundledValidation.isValid)
        XCTAssertEqual(bundledValidation.executableURL, fixture.executable)

        let externalValidation = service.validateExecutable(external)
        XCTAssertFalse(externalValidation.isValid)
        XCTAssertNil(externalValidation.executableURL)
        XCTAssertTrue(externalValidation.message.contains("앱에 포함된 ForgePlay Runtime만 실행 엔진"))
    }

    func testProbeRejectsExternalRuntimeBeforeProcessExecution() async throws {
        let sandbox = temporaryDirectory("ProbeBoundary")
        defer { try? fileManager.removeItem(at: sandbox) }

        let fixture = try makeRuntimeFixture(under: sandbox.appending(path: "Bundled"))
        let external = sandbox.appending(path: "External/wine")
        try writeExecutable(at: external)
        let service = try makeService(
            managedRoot: sandbox.appending(path: "Managed"),
            bundledExecutable: fixture.executable
        )

        do {
            _ = try await service.probe(executable: external)
            XCTFail("An external executable must never reach the process runner.")
        } catch let error as ForgePlayRuntimeCapabilityError {
            guard case .nonBundledRuntimeRejected(let actionName, let path) = error else {
                return XCTFail("Unexpected capability error: \(error)")
            }
            XCTAssertEqual(actionName, "probeRuntime")
            XCTAssertEqual(path, external.path)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProbeReportsUnavailableWhenBundledRuntimeProviderHasNoExecutable() async throws {
        let sandbox = temporaryDirectory("MissingBundledRuntime")
        defer { try? fileManager.removeItem(at: sandbox) }

        let candidate = sandbox.appending(path: "Candidate/wine")
        try writeExecutable(at: candidate)
        let service = try makeService(
            managedRoot: sandbox.appending(path: "Managed"),
            bundledExecutable: nil
        )

        do {
            _ = try await service.probe(executable: candidate)
            XCTFail("A missing bundled runtime must be reported explicitly.")
        } catch let error as ForgePlayRuntimeCapabilityError {
            guard case .bundledRuntimeUnavailable(let actionName) = error else {
                return XCTFail("Unexpected capability error: \(error)")
            }
            XCTAssertEqual(actionName, "probeRuntime")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSupplementalRendererImportKeepsBundledRuntimeAsExecutionEngine() async throws {
        let sandbox = temporaryDirectory("SupplementalImport")
        defer { try? fileManager.removeItem(at: sandbox) }

        let managedRoot = sandbox.appending(path: "Managed")
        let fixture = try makeRuntimeFixture(under: sandbox.appending(path: "Bundled"))
        let source = sandbox.appending(path: "AppleEvaluation")
        let sourceRendererRoot = source.appending(path: "redist/lib")
        try installCompleteD3DMetalPayload(at: sourceRendererRoot)
        let service = try makeService(
            managedRoot: managedRoot,
            bundledExecutable: fixture.executable
        )

        let result = try await service.importAppleSupplementalRenderer(at: source)
        let installedRendererRoot = ForgePlaySupplementalRendererPolicy
            .rendererRoot(forManagedRoot: managedRoot)

        XCTAssertEqual(result.executableURL.standardizedFileURL, fixture.executable.standardizedFileURL)
        XCTAssertEqual(result.installedSupplementalRedistURL?.standardizedFileURL, installedRendererRoot.standardizedFileURL)
        XCTAssertNotEqual(result.executableURL.standardizedFileURL, sourceRendererRoot.appending(path: "wine/bin/wine").standardizedFileURL)
        XCTAssertTrue(result.message.contains("보조 렌더러"))
        XCTAssertTrue(result.message.contains("실행 엔진은 앱에 포함된 ForgePlay Runtime"))

        let capability = try service.inspectRuntimeCapability(executable: fixture.executable)
        XCTAssertEqual(capability.executableURL.standardizedFileURL, fixture.executable.standardizedFileURL)
        XCTAssertEqual(
            capability.supportedDirect3DGenerations(for: .d3dMetal),
            Set([.d3d11, .d3d12])
        )
        XCTAssertTrue(capability.supportsD3DMetalBackend)
    }

    func testSupplementalRendererImportRejectsStandaloneExecutable() async throws {
        let sandbox = temporaryDirectory("RejectStandaloneExecutable")
        defer { try? fileManager.removeItem(at: sandbox) }

        let fixture = try makeRuntimeFixture(under: sandbox.appending(path: "Bundled"))
        let externalExecutable = sandbox.appending(path: "External/wine")
        try writeExecutable(at: externalExecutable)
        let service = try makeService(
            managedRoot: sandbox.appending(path: "Managed"),
            bundledExecutable: fixture.executable
        )

        do {
            _ = try await service.importAppleSupplementalRenderer(at: externalExecutable)
            XCTFail("Supplemental import accepts a payload folder or DMG, never an execution engine.")
        } catch let error as WindowsRuntimeServiceError {
            guard case .invalidSelection(let message) = error else {
                return XCTFail("Unexpected runtime service error: \(error)")
            }
            XCTAssertTrue(message.contains("외부 실행 파일이나 다른 앱의 런타임은 가져오지 않습니다"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnsafeSupplementalSymlinkIsRejectedWithoutReplacingInstalledPayload() async throws {
        let sandbox = temporaryDirectory("RejectUnsafeSymlink")
        defer { try? fileManager.removeItem(at: sandbox) }

        let managedRoot = sandbox.appending(path: "Managed")
        let fixture = try makeRuntimeFixture(under: sandbox.appending(path: "Bundled"))
        let source = sandbox.appending(path: "AppleEvaluation")
        let redistLib = source.appending(path: "redist/lib")
        try installMinimumEvaluationDirectories(at: redistLib)
        let unsafeLink = redistLib.appending(path: "wine/escape")
        try fileManager.createSymbolicLink(atPath: unsafeLink.path, withDestinationPath: "/tmp")

        let service = try makeService(managedRoot: managedRoot, bundledExecutable: fixture.executable)
        let installedRoot = ForgePlaySupplementalRendererPolicy.rendererRoot(forManagedRoot: managedRoot)
        let marker = installedRoot.appending(path: "existing-marker")
        try writeFixtureFile(at: marker)

        do {
            _ = try await service.importAppleSupplementalRenderer(at: source)
            XCTFail("An absolute supplemental payload symlink must be rejected.")
        } catch let error as WindowsRuntimeServiceError {
            guard case .unsafeSupplementalRedistSymlink(let rejectedURL) = error else {
                return XCTFail("Unexpected runtime service error: \(error)")
            }
            XCTAssertEqual(rejectedURL.standardizedFileURL, unsafeLink.standardizedFileURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(fileManager.fileExists(atPath: marker.path))
    }

    func testHardlinkedSupplementalFileIsRejected() async throws {
        let sandbox = temporaryDirectory("RejectHardlink")
        defer { try? fileManager.removeItem(at: sandbox) }

        let fixture = try makeRuntimeFixture(under: sandbox.appending(path: "Bundled"))
        let source = sandbox.appending(path: "AppleEvaluation")
        let redistLib = source.appending(path: "redist/lib")
        try installMinimumEvaluationDirectories(at: redistLib)
        let original = redistLib.appending(path: "wine/original.dll")
        let hardlink = redistLib.appending(path: "wine/hardlinked.dll")
        try writeFixtureFile(at: original)
        try fileManager.linkItem(at: original, to: hardlink)
        let service = try makeService(
            managedRoot: sandbox.appending(path: "Managed"),
            bundledExecutable: fixture.executable
        )

        do {
            _ = try await service.importAppleSupplementalRenderer(at: source)
            XCTFail("Hardlinked supplemental payload files must be rejected.")
        } catch let error as WindowsRuntimeServiceError {
            guard case .unsafeSupplementalRedistHardlink(let rejectedURL) = error else {
                return XCTFail("Unexpected runtime service error: \(error)")
            }
            XCTAssertTrue(
                [original, hardlink]
                    .map(\.standardizedFileURL.path)
                    .contains(rejectedURL.standardizedFileURL.path),
                rejectedURL.path
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHdiutilAttachPlistRequiresAtLeastOneMountPoint() throws {
        let validPlist: [String: Any] = [
            "system-entities": [
                ["dev-entry": "/dev/disk7"],
                ["mount-point": "/Volumes/Evaluation Environment"]
            ]
        ]
        let validData = try PropertyListSerialization.data(
            fromPropertyList: validPlist,
            format: .xml,
            options: 0
        )
        XCTAssertEqual(
            try WindowsRuntimeService.mountedVolumeURLs(
                fromHdiutilAttachPlist: validData,
                diskImageName: "Evaluation.dmg"
            ),
            [URL(fileURLWithPath: "/Volumes/Evaluation Environment")]
        )

        let missingMountData = try PropertyListSerialization.data(
            fromPropertyList: ["system-entities": [["dev-entry": "/dev/disk7"]]],
            format: .xml,
            options: 0
        )
        XCTAssertThrowsError(
            try WindowsRuntimeService.mountedVolumeURLs(
                fromHdiutilAttachPlist: missingMountData,
                diskImageName: "Evaluation.dmg"
            )
        )
        XCTAssertThrowsError(
            try WindowsRuntimeService.mountedVolumeURLs(
                fromHdiutilAttachPlist: Data("not a plist".utf8),
                diskImageName: "Evaluation.dmg"
            )
        )
    }

    func testD9VKRequiresBothWindowsArchitecturesForDirect3D9() throws {
        let sandbox = temporaryDirectory("D9VKClosure")
        defer { try? fileManager.removeItem(at: sandbox) }
        let fixture = try makeRuntimeFixture(under: sandbox)
        try installVulkanHostClosure(at: fixture.root)
        try writeFixtureFile(
            at: fixture.root.appending(path: "Frameworks/renderer/d9vk/wine/x86_64-windows/d3d9.dll")
        )

        var capability = WindowsRuntimeService.inspectRuntimeCapability(
            for: fixture.executable,
            fileManager: fileManager
        )
        XCTAssertFalse(capability.supportsDirect3D9Games)

        try writeFixtureFile(
            at: fixture.root.appending(path: "Frameworks/renderer/d9vk/wine/i386-windows/d3d9.dll")
        )
        capability = WindowsRuntimeService.inspectRuntimeCapability(
            for: fixture.executable,
            fileManager: fileManager
        )
        XCTAssertEqual(
            capability.supportedDirect3DGenerations(for: .moltenVKOrVulkan),
            Set([.d3d9])
        )
    }

    func testDXVKPayloadWithoutAnActualDeviceGateRemainsUnavailable() throws {
        let sandbox = temporaryDirectory("DXVKClosure")
        defer { try? fileManager.removeItem(at: sandbox) }
        let fixture = try makeRuntimeFixture(under: sandbox)
        try installVulkanHostClosure(at: fixture.root)
        let dxvk = fixture.root.appending(path: "Frameworks/renderer/dxvk/wine")
        try writeFixtureFile(at: dxvk.appending(path: "x86_64-windows/d3d11.dll"))
        try writeFixtureFile(at: dxvk.appending(path: "x86_64-windows/dxgi.dll"))

        var capability = WindowsRuntimeService.inspectRuntimeCapability(
            for: fixture.executable,
            fileManager: fileManager
        )
        XCTAssertFalse(capability.supportsDirect3D11Games)

        try writeFixtureFile(at: dxvk.appending(path: "i386-windows/d3d11.dll"))
        try writeFixtureFile(at: dxvk.appending(path: "i386-windows/dxgi.dll"))
        capability = WindowsRuntimeService.inspectRuntimeCapability(
            for: fixture.executable,
            fileManager: fileManager
        )
        XCTAssertTrue(
            capability.supportedDirect3DGenerations(for: .moltenVKOrVulkan)
                .isEmpty
        )
        guard let gate = capability.rendererRuntimeGate(for: .vulkan),
              case .unverified(let technicalDetail) = gate else {
            return XCTFail("Expected an unverified DXVK runtime gate")
        }
        XCTAssertTrue(technicalDetail.contains("no authenticated successful"))
        XCTAssertTrue(
            capability.limitations.contains("dxvk-runtime-gate-unverified")
        )
    }

    func testDXMTRequiresMacDriverMetalWindowBridgeForDirect3D11() throws {
        let sandbox = temporaryDirectory("DXMTClosure")
        defer { try? fileManager.removeItem(at: sandbox) }
        let fixture = try makeRuntimeFixture(under: sandbox)
        try installDXMTClosure(at: fixture.root)

        var capability = WindowsRuntimeService.inspectRuntimeCapability(
            for: fixture.executable,
            fileManager: fileManager
        )
        XCTAssertFalse(capability.supportsD3DMetalBackend)
        XCTAssertTrue(capability.limitations.contains("missing-dxmt-macdrv-metal-window-bridge"))

        try writeFixtureFile(
            at: fixture.root.appending(path: "wine/lib/wine/x86_64-unix/winemac.so"),
            data: Data("binary-prefix _macdrv_functions binary-suffix".utf8)
        )
        capability = WindowsRuntimeService.inspectRuntimeCapability(
            for: fixture.executable,
            fileManager: fileManager
        )
        XCTAssertEqual(
            capability.supportedDirect3DGenerations(for: .d3dMetal),
            Set([.d3d11])
        )
    }

    func testD3DMetalDirect3D11RemainsAvailableWhenDirect3D12ClosureIsIncomplete() throws {
        let sandbox = temporaryDirectory("D3DMetalClosure")
        defer { try? fileManager.removeItem(at: sandbox) }
        let fixture = try makeRuntimeFixture(under: sandbox.appending(path: "Runtime"))
        let rendererRoot = sandbox.appending(path: "SupplementalRenderer")
        try installCompleteD3DMetalPayload(at: rendererRoot)
        try fileManager.removeItem(
            at: rendererRoot.appending(path: "external/D3DMetal.framework/Resources/libmetalirconverter.dylib")
        )

        var capability = WindowsRuntimeService.inspectRuntimeCapability(
            for: fixture.executable,
            supplementalRendererRoot: rendererRoot,
            fileManager: fileManager
        )
        XCTAssertEqual(
            capability.supportedDirect3DGenerations(for: .d3dMetal),
            Set([.d3d11]),
            "A missing Direct3D 12-only resource must not disable a complete Direct3D 11 closure."
        )
        XCTAssertFalse(capability.supportsDirect3D12Games)

        try writeFixtureFile(
            at: rendererRoot.appending(path: "external/D3DMetal.framework/Resources/libmetalirconverter.dylib")
        )
        capability = WindowsRuntimeService.inspectRuntimeCapability(
            for: fixture.executable,
            supplementalRendererRoot: rendererRoot,
            fileManager: fileManager
        )
        XCTAssertEqual(
            capability.supportedDirect3DGenerations(for: .d3dMetal),
            Set([.d3d11, .d3d12])
        )
    }

    func testD3DMetalDirect3D12RequiresItsDirect3D11CompanionClosure() throws {
        let sandbox = temporaryDirectory("D3DMetalD3D12CompanionClosure")
        defer { try? fileManager.removeItem(at: sandbox) }
        let fixture = try makeRuntimeFixture(under: sandbox.appending(path: "Runtime"))
        let rendererRoot = sandbox.appending(path: "SupplementalRenderer")
        try installCompleteD3DMetalPayload(at: rendererRoot)
        try fileManager.removeItem(
            at: rendererRoot.appending(path: "wine/x86_64-windows/d3d11.dll")
        )

        let capability = WindowsRuntimeService.inspectRuntimeCapability(
            for: fixture.executable,
            supplementalRendererRoot: rendererRoot,
            fileManager: fileManager
        )

        XCTAssertFalse(capability.supportedDirect3DGenerations(for: .d3dMetal).contains(.d3d12))
        XCTAssertFalse(capability.supportsDirect3D12Games)
    }

    func testCanonicalAppleD3DMetalFrameworkSymlinksRemainUsable() throws {
        let sandbox = temporaryDirectory("CanonicalD3DMetalFramework")
        defer { try? fileManager.removeItem(at: sandbox) }
        let fixture = try makeRuntimeFixture(under: sandbox.appending(path: "Runtime"))
        let rendererRoot = sandbox.appending(path: "SupplementalRenderer")
        try installCompleteD3DMetalPayload(at: rendererRoot)
        try convertD3DMetalFixtureToCanonicalFramework(at: rendererRoot)

        let capability = WindowsRuntimeService.inspectRuntimeCapability(
            for: fixture.executable,
            supplementalRendererRoot: rendererRoot,
            fileManager: fileManager
        )

        XCTAssertEqual(
            capability.supportedDirect3DGenerations(for: .d3dMetal),
            Set([.d3d11, .d3d12])
        )
        XCTAssertTrue(capability.supportsD3DMetalBackend)
    }

    func testCanonicalD3DMetalFrameworkRejectsEscapingResourceLink() throws {
        let sandbox = temporaryDirectory("EscapingD3DMetalFramework")
        defer { try? fileManager.removeItem(at: sandbox) }
        let fixture = try makeRuntimeFixture(under: sandbox.appending(path: "Runtime"))
        let rendererRoot = sandbox.appending(path: "SupplementalRenderer")
        try installCompleteD3DMetalPayload(at: rendererRoot)
        try convertD3DMetalFixtureToCanonicalFramework(at: rendererRoot)

        let framework = rendererRoot.appending(path: "external/D3DMetal.framework")
        let resourcesLink = framework.appending(path: "Resources")
        try fileManager.removeItem(at: resourcesLink)
        try fileManager.createSymbolicLink(
            atPath: resourcesLink.path,
            withDestinationPath: "/tmp"
        )

        let capability = WindowsRuntimeService.inspectRuntimeCapability(
            for: fixture.executable,
            supplementalRendererRoot: rendererRoot,
            fileManager: fileManager
        )

        XCTAssertFalse(capability.supportsD3DMetalBackend)
        XCTAssertFalse(capability.supportsDirect3D12Games)
    }

    func testManualSelectionResolvesOnlyTheExactAvailableRendererFamily() {
        let executable = URL(fileURLWithPath: "/Applications/ForgePlay.app/Contents/Resources/Runners/ForgePlayRuntime/wine/bin/wine")
        let d3dMetalOnly = WindowsRuntimeCapability(
            executableURL: executable,
            graphicsBackend: .d3dMetal,
            evidence: [
                "Frameworks/renderer/d3dmetal/external/D3DMetal.framework/D3DMetal",
                "Frameworks/renderer/d3dmetal/external/libd3dshared.dylib",
                "Frameworks/renderer/d3dmetal/wine/x86_64-windows/d3d11.dll",
                "Frameworks/renderer/d3dmetal/wine/x86_64-windows/d3d12.dll",
                "Frameworks/renderer/d3dmetal/wine/x86_64-windows/dxgi.dll"
            ],
            limitations: [],
            availableGraphicsBackends: [.d3dMetal],
            supportedDirect3DGenerationsByBackend: [.d3dMetal: [.d3d11, .d3d12]]
        )
        let vulkanOnly = WindowsRuntimeCapability(
            executableURL: executable,
            graphicsBackend: .moltenVKOrVulkan,
            evidence: [
                "Frameworks/renderer/dxvk/wine/x86_64-windows/d3d9.dll",
                "Frameworks/renderer/dxvk/wine/x86_64-windows/d3d11.dll",
                "Frameworks/renderer/dxvk/wine/x86_64-windows/dxgi.dll",
                "Frameworks/renderer/dxvk/wine/i386-windows/d3d9.dll",
                "Frameworks/renderer/dxvk/wine/i386-windows/d3d11.dll",
                "Frameworks/renderer/dxvk/wine/i386-windows/dxgi.dll"
            ],
            limitations: [],
            availableGraphicsBackends: [.moltenVKOrVulkan],
            supportedDirect3DGenerationsByBackend: [.moltenVKOrVulkan: [.d3d9, .d3d11]]
        )

        XCTAssertEqual(
            SteamRendererPolicySelection.d3dMetal.resolvedLaunchPreference(capability: d3dMetalOnly),
            .d3dMetal
        )
        XCTAssertNil(
            SteamRendererPolicySelection.vulkan
                .resolvedLaunchPreference(capability: vulkanOnly)
        )
        XCTAssertEqual(
            SteamRendererPolicyPreference.vulkan
                .availability(in: vulkanOnly)
                .userMessageLocalizationKey,
            SteamRendererPolicyPreference
                .dxvkRuntimeUnavailableLocalizationKey
        )
        XCTAssertNil(
            SteamRendererPolicySelection.vulkan.resolvedLaunchPreference(capability: d3dMetalOnly)
        )
        XCTAssertNil(
            SteamRendererPolicySelection.d3dMetal.resolvedLaunchPreference(capability: vulkanOnly)
        )
    }

    func testPersistedDXVKSelectionIsPreservedAndFailsWithoutImplicitFallback() {
        let executable = URL(
            fileURLWithPath:
                "/Applications/ForgePlay.app/Contents/Resources/Runners/ForgePlayRuntime/wine/bin/wine"
        )
        let capability = WindowsRuntimeCapability(
            executableURL: executable,
            graphicsBackend: .d3dMetal,
            evidence: [],
            limitations: [],
            availableGraphicsBackends: [.d3dMetal],
            supportedDirect3DGenerationsByBackend: [
                .d3dMetal: [.d3d11, .d3d12]
            ]
        )

        for persistedValue in ["vulkan", "dxvk"] {
            let selection = SteamRendererPolicySelection.persistedValue(
                persistedValue
            )
            XCTAssertEqual(selection, .vulkan)
            XCTAssertNil(
                selection.resolvedLaunchPreference(capability: capability)
            )
        }
    }

    func testCombinedCuratedPayloadReportsDirect3D9_11_12WithoutConflatingBackends() throws {
        let sandbox = temporaryDirectory("CombinedClosure")
        defer { try? fileManager.removeItem(at: sandbox) }
        let fixture = try makeRuntimeFixture(under: sandbox.appending(path: "Runtime"))
        let rendererRoot = sandbox.appending(path: "SupplementalRenderer")
        try installCompleteD3DMetalPayload(at: rendererRoot)
        try installVulkanHostClosure(at: fixture.root)
        try installD9VKClosure(at: fixture.root)
        try installDXVKClosure(at: fixture.root)

        let capability = WindowsRuntimeService.inspectRuntimeCapability(
            for: fixture.executable,
            supplementalRendererRoot: rendererRoot,
            fileManager: fileManager
        )

        XCTAssertEqual(
            capability.supportedDirect3DGenerations(for: .d3dMetal),
            Set([.d3d11, .d3d12])
        )
        XCTAssertEqual(
            capability.supportedDirect3DGenerations(for: .moltenVKOrVulkan),
            Set([.d3d9])
        )
        XCTAssertEqual(capability.supportedDirect3DGenerations, Set([.d3d9, .d3d11, .d3d12]))
        XCTAssertEqual(capability.availableGraphicsBackends, Set([.d3dMetal, .moltenVKOrVulkan]))
        XCTAssertEqual(
            SteamRendererPolicySelection.d3dMetal.resolvedLaunchPreference(capability: capability),
            .d3dMetal
        )
        XCTAssertNil(
            SteamRendererPolicySelection.vulkan
                .resolvedLaunchPreference(capability: capability)
        )
        XCTAssertEqual(
            SteamRendererPolicySelection.d9vk
                .resolvedLaunchPreference(capability: capability),
            .d9vk
        )
    }

    func testSteamWebHelperRootScopedArgumentPolicyRequiresAllMarkersInBothKernelbases() throws {
        let sandbox = temporaryDirectory("SteamWebHelperArgumentPolicy")
        defer { try? fileManager.removeItem(at: sandbox) }
        let fixture = try makeRuntimeFixture(
            under: sandbox.appending(path: "Runtime")
        )
        let kernelbases: [(url: URL, encoding: String.Encoding)] = [
            (
                fixture.root.appending(
                    path: "wine/lib/wine/i386-windows/kernelbase.dll"
                ),
                .utf8
            ),
            (
                fixture.root.appending(
                    path: "wine/lib/wine/x86_64-windows/kernelbase.dll"
                ),
                .utf16LittleEndian
            )
        ]
        let limitation =
            "missing-steam-webhelper-root-scoped-executable-argument-policy"

        for kernelbase in kernelbases {
            try writeSteamWebHelperRootScopedArgumentPolicyKernelbase(
                at: kernelbase.url,
                encoding: kernelbase.encoding
            )
        }

        var capability = WindowsRuntimeService.inspectRuntimeCapability(
            for: fixture.executable,
            fileManager: fileManager
        )
        XCTAssertFalse(capability.limitations.contains(limitation))
        XCTAssertTrue(
            capability.evidence.contains(
                "Steam WebHelper root-process-scoped executable argument mechanism in i386/x86_64 kernelbase"
            )
        )

        for kernelbase in kernelbases {
            let originalData = try Data(contentsOf: kernelbase.url)
            try fileManager.removeItem(at: kernelbase.url)
            capability = WindowsRuntimeService.inspectRuntimeCapability(
                for: fixture.executable,
                fileManager: fileManager
            )
            XCTAssertTrue(
                capability.limitations.contains(limitation),
                "Missing \(kernelbase.url.path) must fail closed"
            )
            try writeFixtureFile(at: kernelbase.url, data: originalData)
        }

        for kernelbase in kernelbases {
            for omittedMarker in steamWebHelperRootScopedArgumentPolicyMarkers {
                try writeSteamWebHelperRootScopedArgumentPolicyKernelbase(
                    at: kernelbase.url,
                    encoding: kernelbase.encoding,
                    omitting: omittedMarker
                )
                capability = WindowsRuntimeService.inspectRuntimeCapability(
                    for: fixture.executable,
                    fileManager: fileManager
                )
                XCTAssertTrue(
                    capability.limitations.contains(limitation),
                    "Missing \(omittedMarker) in \(kernelbase.url.path) must fail closed"
                )
            }
            try writeSteamWebHelperRootScopedArgumentPolicyKernelbase(
                at: kernelbase.url,
                encoding: kernelbase.encoding
            )
        }
    }

    func testCapabilityGenerationTracksBothArgumentPolicyKernelbases() throws {
        let sandbox = temporaryDirectory("ArgumentPolicyGeneration")
        defer { try? fileManager.removeItem(at: sandbox) }
        let fixture = try makeRuntimeFixture(
            under: sandbox.appending(path: "Runtime")
        )
        let kernelbases = [
            fixture.root.appending(
                path: "wine/lib/wine/i386-windows/kernelbase.dll"
            ),
            fixture.root.appending(
                path: "wine/lib/wine/x86_64-windows/kernelbase.dll"
            )
        ]
        let candidatePaths = Set(
            WindowsRuntimeService.runtimeCapabilityGenerationCandidateURLs(
                for: fixture.executable,
                supplementalRendererRoot: nil,
                fileManager: fileManager
            ).map(\.standardizedFileURL.path)
        )
        XCTAssertTrue(kernelbases.allSatisfy {
            candidatePaths.contains($0.standardizedFileURL.path)
        })

        var generation = try WindowsRuntimeCapabilityGeneration.capture(
            executable: fixture.executable,
            supplementalRendererRoot: nil
        )
        for (index, kernelbase) in kernelbases.enumerated() {
            try writeFixtureFile(
                at: kernelbase,
                data: Data("argument-policy-generation-\(index)".utf8)
            )
            let updatedGeneration = try WindowsRuntimeCapabilityGeneration.capture(
                executable: fixture.executable,
                supplementalRendererRoot: nil
            )
            XCTAssertNotEqual(generation, updatedGeneration)
            generation = updatedGeneration
        }
    }

    func testCapabilityProviderCoalescesSameGenerationOffMainActor()
        async throws
    {
        let sandbox = temporaryDirectory("CapabilityProviderCoalescing")
        defer { try? fileManager.removeItem(at: sandbox) }
        let fixture = try makeRuntimeFixture(
            under: sandbox.appending(path: "Runtime")
        )
        let probe = RuntimeCapabilityInspectionProbe(delay: 0.05)
        let provider = WindowsRuntimeCapabilityProvider(
            inspector: { executable, supplementalRendererRoot in
                try probe.inspect(
                    executable: executable,
                    supplementalRendererRoot: supplementalRendererRoot
                )
            }
        )

        async let first = provider.snapshot(for: fixture.executable)
        async let second = provider.snapshot(for: fixture.executable)
        let (firstSnapshot, secondSnapshot) = try await (first, second)

        XCTAssertEqual(firstSnapshot, secondSnapshot)
        XCTAssertEqual(probe.inspectionCount, 1)
        XCTAssertFalse(probe.didInspectOnMainThread)
    }

    func testCapabilityProviderRetriesWhenNestedRendererGenerationChanges()
        async throws
    {
        let sandbox = temporaryDirectory("CapabilityProviderMutation")
        defer { try? fileManager.removeItem(at: sandbox) }
        let fixture = try makeRuntimeFixture(
            under: sandbox.appending(path: "Runtime")
        )
        let nestedRenderer = fixture.root.appending(
            path: "Frameworks/renderer/dxvk/wine/x86_64-windows/d3d9.dll"
        )
        let probe = RuntimeCapabilityInspectionProbe { inspectionIndex in
            guard inspectionIndex == 1 else { return }
            try FileManager.default.createDirectory(
                at: nestedRenderer.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("generation-b".utf8).write(to: nestedRenderer)
        }
        let provider = WindowsRuntimeCapabilityProvider(
            inspector: { executable, supplementalRendererRoot in
                try probe.inspect(
                    executable: executable,
                    supplementalRendererRoot: supplementalRendererRoot
                )
            }
        )

        let snapshot = try await provider.snapshot(for: fixture.executable)
        let cached = try await provider.snapshot(for: fixture.executable)

        XCTAssertEqual(snapshot, cached)
        XCTAssertEqual(probe.inspectionCount, 2)
        XCTAssertFalse(probe.didInspectOnMainThread)
    }

    func testRuntimeManifestProjectsCapabilityOwnersFromAuthenticatedCorePayloads() throws {
        let runtimeFingerprint =
            WindowsExecutionSHA256.hash(Data("runtime".utf8)).hexadecimal
        let payloadFingerprint =
            WindowsExecutionSHA256.hash(Data("payload".utf8)).hexadecimal
        let ownerPath = "wine/bin/wineserver"
        let manifest = RuntimeManifest(
            schemaVersion: RuntimeManifest.currentSchemaVersion,
            runtimeIdentifier: "forgeplay.test.runtime",
            wineVersion: "test",
            architecture: "x86_64",
            sourceTreeSHA256: nil,
            patchSetSHA256: nil,
            runnerLauncherSHA256: payloadFingerprint,
            wineInfSHA256: payloadFingerprint,
            winebootSHA256: payloadFingerprint,
            prefixCompatibilityFingerprint: payloadFingerprint,
            runnerBuildFingerprint: runtimeFingerprint,
            corePayloadHashAlgorithm:
                RuntimeManifest.currentCorePayloadHashAlgorithm,
            corePayloadSHA256: [ownerPath: payloadFingerprint]
        )
        let declaration = RuntimeWindowsExecutionCapabilityDeclaration(
            lowercaseASCIIIdentifier:
                "forgeplay.windows.execution.test-capability",
            major: 1,
            minor: 2,
            owningCorePayloadPath: ownerPath
        )

        let projected = try manifest.windowsExecutionCapabilityManifest(
            declarations: [declaration],
            supportedPEMachines: [.pe32I386, .pe32PlusAMD64]
        )

        XCTAssertEqual(
            projected.runtimeFingerprintSHA256.hexadecimal,
            runtimeFingerprint
        )
        XCTAssertEqual(projected.capabilities.count, 1)
        XCTAssertEqual(
            projected.capabilities[0].owningCorePayloadSHA256.hexadecimal,
            payloadFingerprint
        )
        XCTAssertEqual(
            projected.supportedPEMachines,
            [.pe32I386, .pe32PlusAMD64]
        )
    }

    private struct RuntimeFixture {
        let root: URL
        let executable: URL
    }

    private var steamWebHelperRootScopedArgumentPolicyMarkers: [String] {
        [
            SteamWebHelperLaunchPolicy.argumentTargetEnvironmentKey,
            SteamWebHelperLaunchPolicy.argumentAppendEnvironmentKey,
            SteamWebHelperLaunchPolicy.argumentRootOnlyEnvironmentKey
        ]
    }

    private func temporaryDirectory(_ label: String) -> URL {
        fileManager.temporaryDirectory.appending(
            path: "ForgePlay-WindowsRuntimeServiceTests-\(label)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func makeRuntimeFixture(under root: URL) throws -> RuntimeFixture {
        let executable = root.appending(path: "wine/bin/wine")
        try writeExecutable(at: executable)
        return RuntimeFixture(root: root, executable: executable)
    }

    private func makeService(
        managedRoot: URL,
        bundledExecutable: URL?
    ) throws -> WindowsRuntimeService {
        let pathManager = PathManager(fileManager: fileManager)
        try pathManager.configureRoot(managedRoot)
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
        return WindowsRuntimeService(
            pathManager: pathManager,
            runner: runner,
            fileManager: fileManager,
            bundledRuntimeExecutableProvider: { bundledExecutable }
        )
    }

    private func writeExecutable(at url: URL) throws {
        try writeFixtureFile(
            at: url,
            data: Data("#!/bin/sh\nprintf 'wine-ForgePlay-test\\n'\nexit 0\n".utf8)
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func writeFixtureFile(
        at url: URL,
        data: Data = Data("fixture".utf8)
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func writeSteamWebHelperRootScopedArgumentPolicyKernelbase(
        at url: URL,
        encoding: String.Encoding,
        omitting omittedMarker: String? = nil
    ) throws {
        var data = Data("kernelbase-fixture\n".utf8)
        for marker in steamWebHelperRootScopedArgumentPolicyMarkers
        where marker != omittedMarker {
            data.append(try XCTUnwrap(marker.data(using: encoding)))
            if encoding == .utf16LittleEndian {
                data.append(contentsOf: [0, 0])
            } else {
                data.append(0)
            }
        }
        try writeFixtureFile(at: url, data: data)
    }

    private func installMinimumEvaluationDirectories(at rendererRoot: URL) throws {
        try fileManager.createDirectory(
            at: rendererRoot.appending(path: "external/D3DMetal.framework", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: rendererRoot.appending(path: "wine", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    private func installCompleteD3DMetalPayload(at rendererRoot: URL) throws {
        try installMinimumEvaluationDirectories(at: rendererRoot)

        let frameworkResources = rendererRoot.appending(
            path: "external/D3DMetal.framework/Resources",
            directoryHint: .isDirectory
        )
        try writeFixtureFile(at: rendererRoot.appending(path: "external/D3DMetal.framework/D3DMetal"))
        let infoPlist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": "D3DMetal",
                "CFBundleShortVersionString": "4.1",
                "CFBundleVersion": "4100"
            ],
            format: .xml,
            options: 0
        )
        try writeFixtureFile(at: frameworkResources.appending(path: "Info.plist"), data: infoPlist)
        for name in [
            "default.metallib",
            "libdxccontainer.dylib",
            "libdxcompiler.dylib",
            "libdxilconv.dylib",
            "libmetalirconverter.dylib"
        ] {
            try writeFixtureFile(at: frameworkResources.appending(path: name))
        }

        try writeFixtureFile(at: rendererRoot.appending(path: D3DMetalRendererPayloadContract.sharedLibraryRelativePath))
        for relativePath in D3DMetalRendererPayloadContract.sharedUnixModuleRelativePaths {
            let link = rendererRoot.appending(path: relativePath)
            try fileManager.createDirectory(
                at: link.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: D3DMetalRendererPayloadContract.sharedUnixModuleLinkTarget
            )
        }

        for relativePath in [
            "wine/x86_64-windows/d3d10.dll",
            "wine/x86_64-windows/d3d11.dll",
            "wine/x86_64-windows/d3d12.dll",
            "wine/x86_64-windows/dxgi.dll",
            "wine/x86_64-windows/nvapi.dll",
            "wine/x86_64-windows/nvapi64.dll",
            "wine/x86_64-windows/nvngx-on-metalfx.dll"
        ] {
            try writeFixtureFile(at: rendererRoot.appending(path: relativePath))
        }
        try Data(
            contentsOf: rendererRoot.appending(
                path: D3DMetalNVAPIAliasContract.sourceWindowsModuleRelativePath
            )
        ).write(
            to: rendererRoot.appending(
                path: D3DMetalNVAPIAliasContract.windowsAliasRelativePath
            )
        )
    }

    private func convertD3DMetalFixtureToCanonicalFramework(at rendererRoot: URL) throws {
        let framework = rendererRoot.appending(path: "external/D3DMetal.framework")
        let versionA = framework.appending(path: "Versions/A")
        try fileManager.createDirectory(at: versionA, withIntermediateDirectories: true)
        try fileManager.moveItem(
            at: framework.appending(path: "D3DMetal"),
            to: versionA.appending(path: "D3DMetal")
        )
        try fileManager.moveItem(
            at: framework.appending(path: "Resources"),
            to: versionA.appending(path: "Resources")
        )
        try fileManager.createSymbolicLink(
            atPath: framework.appending(path: "Versions/Current").path,
            withDestinationPath: "A"
        )
        try fileManager.createSymbolicLink(
            atPath: framework.appending(path: "D3DMetal").path,
            withDestinationPath: "Versions/Current/D3DMetal"
        )
        try fileManager.createSymbolicLink(
            atPath: framework.appending(path: "Resources").path,
            withDestinationPath: "Versions/Current/Resources"
        )
    }

    private func installVulkanHostClosure(at runtimeRoot: URL) throws {
        for relativePath in [
            "wine/lib/libvulkan.dylib",
            "wine/lib/libMoltenVK.dylib",
            "wine/etc/vulkan/icd.d/MoltenVK_icd.json"
        ] {
            try writeFixtureFile(at: runtimeRoot.appending(path: relativePath))
        }
    }

    private func installD9VKClosure(at runtimeRoot: URL) throws {
        for architecture in ["x86_64-windows", "i386-windows"] {
            try writeFixtureFile(
                at: runtimeRoot.appending(
                    path: "Frameworks/renderer/d9vk/wine/\(architecture)/d3d9.dll"
                )
            )
        }
    }

    private func installDXVKClosure(at runtimeRoot: URL) throws {
        for architecture in ["x86_64-windows", "i386-windows"] {
            for module in ["d3d9.dll", "d3d11.dll", "dxgi.dll"] {
                try writeFixtureFile(
                    at: runtimeRoot.appending(
                        path: "Frameworks/renderer/dxvk/wine/\(architecture)/\(module)"
                    )
                )
            }
        }
    }

    private func installDXMTClosure(at runtimeRoot: URL) throws {
        let rendererRoot = runtimeRoot.appending(path: "Frameworks/renderer/dxmt/wine")
        try writeFixtureFile(at: rendererRoot.appending(path: "x86_64-unix/winemetal.so"))
        for architecture in ["x86_64-windows", "i386-windows"] {
            for module in ["d3d11.dll", "dxgi.dll", "winemetal.dll"] {
                try writeFixtureFile(
                    at: rendererRoot.appending(path: "\(architecture)/\(module)")
                )
            }
        }
    }
}
