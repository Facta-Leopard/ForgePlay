import CryptoKit
import Darwin
import XCTest
@testable import ForgePlay

private final class RuntimeAuthenticationInvocationCounter:
    @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    private var invokedOnMainThreadStorage = false

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var wasInvokedOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invokedOnMainThreadStorage
    }

    func increment() {
        lock.lock()
        storage += 1
        invokedOnMainThreadStorage =
            invokedOnMainThreadStorage || Thread.isMainThread
        lock.unlock()
    }
}

final class BundledWindowsRuntimePolicyTests: XCTestCase {
    func testAppStoreRuntimePayloadPreparationRemovesOnlyAppleRenderer() throws {
        let repositoryRoot = Self.repositoryRoot()
        let script = repositoryRoot.appending(path: "Scripts/prepare-app-store-runtime-payload.sh")
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayAppStoreRuntimeFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let runtime = fixtureRoot.appending(path: "Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let d3dMetal = runtime.appending(
            path: "Frameworks/renderer/d3dmetal/external/D3DMetal.framework/D3DMetal"
        )
        let dxvk = runtime.appending(path: "Frameworks/renderer/dxvk/wine/x86_64-windows/d3d11.dll")
        try FileManager.default.createDirectory(
            at: d3dMetal.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: dxvk.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("apple-renderer".utf8).write(to: d3dMetal)
        try Data("dxvk-renderer".utf8).write(to: dxvk)
        let runtimeInfo = try PropertyListSerialization.data(
            fromPropertyList: [
                "D3DMETAL": true,
                "DXMT": true,
                "DXVK": true
            ],
            format: .xml,
            options: 0
        )
        try runtimeInfo.write(to: runtime.appending(path: "Info.plist"))
        try """
        # ForgePlay Runtime Build Metadata
        - Game graphics runtime: Apple GPTK Evaluation Environment redist
        - D3DMetal overlay source: local development
        - App Store/commercial note: Apple GPTK/D3DMetal review required
        """.write(
            to: runtime.appending(path: "BUILD-METADATA.md"),
            atomically: true,
            encoding: .utf8
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, fixtureRoot.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let outputText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, outputText)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: runtime.appending(path: "Frameworks/renderer/d3dmetal").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dxvk.path))
        let metadata = try String(
            contentsOf: runtime.appending(path: "BUILD-METADATA.md"),
            encoding: .utf8
        )
        XCTAssertFalse(metadata.contains("Game graphics runtime: Apple GPTK"))
        XCTAssertTrue(metadata.contains("Apple GPTK/D3DMetal evaluation redist excluded"))
        XCTAssertTrue(metadata.contains("Vulkan, MoltenVK, DXVK, DXMT"))
        let preparedInfo = try XCTUnwrap(
            NSDictionary(contentsOf: runtime.appending(path: "Info.plist")) as? [String: Any]
        )
        XCTAssertEqual(preparedInfo["D3DMETAL"] as? Bool, false)
        XCTAssertEqual(preparedInfo["DXMT"] as? Bool, true)
        XCTAssertEqual(preparedInfo["DXVK"] as? Bool, true)
    }

    func testSourceBundledRuntimePackageIsPolicyCompliant() throws {
        let resourceRoot = Self.repositoryRoot()
            .appending(path: "Resources", directoryHint: .isDirectory)
        let runtimeRoot = resourceRoot
            .appending(path: "Runners/ForgePlayRuntime", directoryHint: .isDirectory)

        let executable = try ForgePlayBundledWindowsRuntimePolicy.requiredBundledRuntimeExecutable(
            inResourceRoot: resourceRoot
        )

        XCTAssertEqual(
            executable.standardizedFileURL.path,
            runtimeRoot.appending(path: "wine/bin/wine").standardizedFileURL.path
        )

        for requiredPath in [
            "wine/bin/wine",
            "wine/bin/wineserver",
            "wine/bin/wineboot",
            "wine/bin/msiexec",
            "wine/lib/wine/x86_64-windows/forgeplay-steam-launcher.exe",
            "wine/lib/libfreetype.6.dylib",
            "wine/lib/libgnutls.30.dylib",
            "wine/lib/libvulkan.1.dylib",
            "wine/lib/libMoltenVK.dylib",
            "wine/etc/vulkan/icd.d/MoltenVK_icd.json",
            "wine/lib/wine/x86_64-unix/ntdll.so",
            "wine/lib/wine/x86_64-unix/dwrite.so",
            "wine/lib/wine/x86_64-unix/win32u.so",
            "wine/lib/wine/x86_64-unix/winegstreamer.so",
            "wine/lib/wine/x86_64-unix/winevulkan.so",
            "wine/lib/wine/x86_64-windows/kernelbase.dll",
            "wine/lib/wine/x86_64-windows/mfplat.dll",
            "wine/lib/wine/x86_64-windows/ntdll.dll",
            "wine/lib/wine/x86_64-windows/schannel.dll",
            "wine/lib/wine/x86_64-windows/winegstreamer.dll",
            "wine/lib/wine/x86_64-windows/winevulkan.dll",
            "wine/lib/wine/i386-windows/ntdll.dll",
            "wine/lib/wine/i386-windows/kernelbase.dll",
            "wine/lib/wine/i386-windows/mfplat.dll",
            "wine/lib/wine/i386-windows/schannel.dll",
            "wine/lib/wine/i386-windows/winegstreamer.dll",
            "wine/lib/wine/i386-windows/winevulkan.dll",
            "wine/gstreamer/lib/libgstreamer-1.0.0.dylib",
            "wine/gstreamer/lib/libgstrtsp-1.0.0.dylib",
            "wine/gstreamer/lib/libgstsdp-1.0.0.dylib",
            "wine/gstreamer/lib/gstreamer-1.0/libgstasf.dylib",
            "wine/gstreamer/lib/gstreamer-1.0/libgstdeinterlace.dylib",
            "wine/gstreamer/lib/gstreamer-1.0/libgstisomp4.dylib",
            "wine/gstreamer/lib/gstreamer-1.0/libgstapplemedia.dylib",
            "wine/gstreamer/lib/gstreamer-1.0/libgstlibav.dylib",
            "wine/gstreamer/lib/gstreamer-1.0/libgstvideofilter.dylib",
            "Frameworks/renderer/d3dmetal/external/D3DMetal.framework/D3DMetal",
            "Frameworks/renderer/d3dmetal/external/D3DMetal.framework/Versions/A/D3DMetal",
            "Frameworks/renderer/d3dmetal/external/D3DMetal.framework/Resources/default.metallib",
            "Frameworks/renderer/d3dmetal/external/libd3dshared.dylib",
            "Frameworks/renderer/d3dmetal/wine/x86_64-unix/d3d10.so",
            "Frameworks/renderer/d3dmetal/wine/x86_64-unix/d3d11.so",
            "Frameworks/renderer/d3dmetal/wine/x86_64-unix/d3d12.so",
            "Frameworks/renderer/d3dmetal/wine/x86_64-unix/dxgi.so",
            "Frameworks/renderer/d3dmetal/wine/x86_64-unix/nvapi.so",
            "Frameworks/renderer/d3dmetal/wine/x86_64-unix/nvapi64.so",
            "Frameworks/renderer/d3dmetal/wine/x86_64-unix/nvngx-on-metalfx.so",
            "Frameworks/renderer/d3dmetal/wine/x86_64-windows/d3d11.dll",
            "Frameworks/renderer/d3dmetal/wine/x86_64-windows/dxgi.dll",
            "Frameworks/renderer/d3dmetal/wine/x86_64-windows/nvapi.dll",
            "Frameworks/renderer/d3dmetal/wine/x86_64-windows/nvapi64.dll",
            "Frameworks/renderer/d9vk/wine/i386-windows/d3d9.dll",
            "Frameworks/renderer/d9vk/wine/x86_64-windows/d3d9.dll",
            "Frameworks/renderer/dxvk/wine/i386-windows/d3d8.dll",
            "Frameworks/renderer/dxvk/wine/i386-windows/d3d9.dll",
            "Frameworks/renderer/dxvk/wine/i386-windows/d3d10core.dll",
            "Frameworks/renderer/dxvk/wine/i386-windows/d3d11.dll",
            "Frameworks/renderer/dxvk/wine/i386-windows/dxgi.dll",
            "Frameworks/renderer/dxvk/wine/x86_64-windows/d3d8.dll",
            "Frameworks/renderer/dxvk/wine/x86_64-windows/d3d9.dll",
            "Frameworks/renderer/dxvk/wine/x86_64-windows/d3d10core.dll",
            "Frameworks/renderer/dxvk/wine/x86_64-windows/d3d11.dll",
            "Frameworks/renderer/dxvk/wine/x86_64-windows/dxgi.dll",
            "Frameworks/renderer/dxmt/wine/i386-windows/d3d11.dll",
            "Frameworks/renderer/dxmt/wine/i386-windows/dxgi.dll",
            "Frameworks/renderer/dxmt/wine/i386-windows/winemetal.dll",
            "Frameworks/renderer/dxmt/wine/x86_64-unix/winemetal.so",
            "Frameworks/renderer/dxmt/wine/x86_64-windows/d3d11.dll",
            "Frameworks/renderer/dxmt/wine/x86_64-windows/dxgi.dll",
            "Frameworks/renderer/dxmt/wine/x86_64-windows/winemetal.dll",
            "wine/share/wine/wine.inf",
            "Legal/Wine/LICENSE",
            "Legal/Wine/COPYING.LIB",
            "Legal/FreeType/LICENSE.TXT",
            "Legal/GStreamer/GStreamer/LGPL-2.0-or-later.txt",
            "Legal/GStreamer/GStreamerLibav/LGPL-2.0-or-later.txt",
            "Legal/GStreamer/GStreamerUgly/LGPL-2.0-or-later.txt",
            "Legal/AppleGPTK/License.rtf",
            "Legal/AppleGPTK/Acknowledgements.rtf",
            "Sources/forgeplay_steam_launcher.c",
            "Patches/wine-11.12-forgeplay-d3dmetal-bridge.patch",
            "Patches/wine-11.12-forgeplay-d3dmetal-bridge-contract.md",
            "Patches/wine-11.12-forgeplay-metal-window-surface-contract.patch",
            "Patches/wine-11.12-steam-game-renderer-process-policy.patch",
            "RuntimeSBOM.json",
            "BUILD-METADATA.md",
            "SOURCE-AVAILABILITY.md"
        ] {
            let url = runtimeRoot.appending(path: requiredPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing \(requiredPath)")
        }

        for forbiddenPath in [
            "wine/lib/external/D3DMetal.framework",
            "wine/lib/external/libd3dshared.dylib",
            "wine/lib/wine/x86_64-unix/d3d10.so",
            "wine/lib/wine/x86_64-unix/d3d11.so",
            "wine/lib/wine/x86_64-unix/d3d12.so",
            "wine/lib/wine/x86_64-unix/dxgi.so",
            "wine/lib/wine/x86_64-unix/libd3dshared.dylib",
            "wine/lib/wine/x86_64-unix/nvapi.so",
            "wine/lib/wine/x86_64-unix/nvapi64.so",
            "wine/lib/wine/x86_64-unix/nvngx-on-metalfx.so",
            "wine/lib/wine/x86_64-windows/nvapi.dll",
            "wine/lib/wine/x86_64-windows/nvapi64.dll",
            "wine/lib/wine/x86_64-windows/nvngx-on-metalfx.dll"
        ] {
            let url = runtimeRoot.appending(path: forbiddenPath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Active Wine module path must not contain renderer overlay: \(forbiddenPath)")
        }

        let enumerator = FileManager.default.enumerator(
            at: runtimeRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .linkCountKey],
            options: [.skipsHiddenFiles]
        )
        let runtimeEnumerator = try XCTUnwrap(enumerator)
        let allowedD3DMetalSymlinks = Set(
            D3DMetalRendererPayloadContract.sharedUnixModuleRelativePaths.map {
                runtimeRoot.appending(path: "Frameworks/renderer/d3dmetal/\($0)").standardizedFileURL.path
            }
        )
        let d3dMetalSharedLibrary = runtimeRoot.appending(
            path: "Frameworks/renderer/d3dmetal/\(D3DMetalRendererPayloadContract.sharedLibraryRelativePath)"
        )

        for case let url as URL in runtimeEnumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .linkCountKey])
            if values.isSymbolicLink == true {
                XCTAssertTrue(
                    allowedD3DMetalSymlinks.contains(url.standardizedFileURL.path),
                    "Bundled runtime contains an unapproved symlink: \(url.path)"
                )
                XCTAssertEqual(
                    try FileManager.default.destinationOfSymbolicLink(atPath: url.path),
                    D3DMetalRendererPayloadContract.sharedUnixModuleLinkTarget
                )
                XCTAssertEqual(
                    url.resolvingSymlinksInPath().standardizedFileURL.path,
                    d3dMetalSharedLibrary.standardizedFileURL.path
                )
                continue
            }
            if values.isRegularFile == true {
                XCTAssertLessThanOrEqual(values.linkCount ?? 1, 1, "Bundled runtime contains hardlink: \(url.path)")
            }
        }

        for architecture in ["i386-windows", "x86_64-windows"] {
            let kernelbase = runtimeRoot.appending(path: "wine/lib/wine/\(architecture)/kernelbase.dll")
            let ntdll = runtimeRoot.appending(path: "wine/lib/wine/\(architecture)/ntdll.dll")
            XCTAssertTrue(
                try Self.binary(kernelbase, contains: "ForgePlay Steam game renderer process policy for"),
                "Missing game process policy in \(architecture) kernelbase"
            )
            XCTAssertTrue(
                try Self.binary(kernelbase, contains: "FORGEPLAY_GAME_RENDERER_ROUTE_V2"),
                "Missing game route evidence in \(architecture) kernelbase"
            )
            XCTAssertTrue(
                try Self.binary(
                    kernelbase,
                    contains: "FORGEPLAY_GAME_RENDERER_ENVIRONMENT_V1"
                ),
                "Missing renderer environment failure evidence in \(architecture) kernelbase"
            )
            XCTAssertTrue(
                try Self.binary(kernelbase, contains: "FORGEPLAY_GAME_RENDERER_FALLBACK_V1"),
                "Missing renderer fail-open evidence in \(architecture) kernelbase"
            )
            XCTAssertTrue(
                try Self.binary(ntdll, contains: "applied ForgePlay Steam game renderer DLL search path"),
                "Missing game renderer DLL loader policy in \(architecture) ntdll"
            )
        }
        XCTAssertTrue(
            try Self.binary(
                runtimeRoot.appending(path: "wine/lib/wine/x86_64-unix/ntdll.so"),
                contains: "synchronized ForgePlay Steam game process Unix environment"
            ),
            "Missing Steam game process Unix environment synchronization"
        )
        for marker in [
            "FORGEPLAY_GAME_MODE_HOST_ENABLED",
            "loader_contract_rejected",
            "loader_exec_failed"
        ] {
            XCTAssertTrue(
                try Self.binary(
                    runtimeRoot.appending(path: "wine/lib/wine/x86_64-unix/ntdll.so"),
                    contains: marker
                ),
                "Missing Game Mode loader-host fallback contract marker: \(marker)"
            )
        }
        let winemacSymbols = try Self.exportedSymbols(
            runtimeRoot.appending(path: "wine/lib/wine/x86_64-unix/winemac.so")
        )
        XCTAssertTrue(
            winemacSymbols.split(whereSeparator: \.isWhitespace).contains("_macdrv_functions"),
            "Missing Metal renderer window-surface contract export"
        )
    }

    func testRuntimeManifestUsesContentIdentityAndRejectsPayloadTampering() throws {
        let sourceRuntime = Self.repositoryRoot()
            .appending(path: "Resources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeManifestTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let sbomData = try Data(contentsOf: sourceRuntime.appending(path: "RuntimeSBOM.json"))
        let sbom = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sbomData) as? [String: Any]
        )
        XCTAssertEqual(
            sbom["schemaVersion"] as? Int,
            RuntimeManifest.currentHostSupportSBOMSchemaVersion
        )
        let hostSupportPayload = try XCTUnwrap(
            sbom["hostSupportPayload"] as? [[String: Any]]
        )
        let gstreamerPayloadEntries = hostSupportPayload.filter { entry in
            guard let path = entry["path"] as? String,
                  path.hasPrefix("wine/gstreamer/"),
                  path.hasSuffix(".dylib") else {
                return false
            }
            return true
        }
        let gstreamerPayloadPaths = gstreamerPayloadEntries.compactMap {
            $0["path"] as? String
        }
        XCTAssertFalse(gstreamerPayloadPaths.isEmpty)
        for entry in gstreamerPayloadEntries {
            XCTAssertEqual(
                entry["consumptionHashAlgorithm"] as? String,
                RuntimeManifest.currentCorePayloadHashAlgorithm
            )
            let digest = try XCTUnwrap(entry["consumptionSHA256"] as? String)
            XCTAssertEqual(digest.count, 64)
            XCTAssertTrue(
                digest.allSatisfy { character in
                    character.isNumber || ("a"..."f").contains(character)
                }
            )
        }

        let copiedFiles = Set([
            "RuntimeManifest.json",
            "RuntimeSBOM.json",
            "wine/bin/wine",
            "wine/share/wine/wine.inf",
            "wine/lib/wine/x86_64-windows/wineboot.exe"
        ])
            .union(RuntimeManifest.requiredCorePayloadPaths)
            .union(gstreamerPayloadPaths)
            .sorted()
        for relativePath in copiedFiles {
            let source = sourceRuntime.appending(path: relativePath)
            let destination = root.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let executable = root.appending(path: "wine/bin/wine")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolver = RuntimeManifestResolver()
        let authenticatedContext = try resolver.authenticatedContext(
            for: executable
        )
        let initial = authenticatedContext.manifest
        let changedDate = Date(timeIntervalSince1970: 1)
        for relativePath in copiedFiles {
            try FileManager.default.setAttributes(
                [.modificationDate: changedDate],
                ofItemAtPath: root.appending(path: relativePath).path
            )
        }
        let afterMtimeChange = try RuntimeManifestResolver().manifest(for: executable)

        XCTAssertEqual(initial, afterMtimeChange)
        XCTAssertEqual(initial.schemaVersion, RuntimeManifest.currentSchemaVersion)
        XCTAssertEqual(initial.architecture, WinePrefixDefaults.architecture)
        XCTAssertEqual(
            initial.corePayloadHashAlgorithm,
            RuntimeManifest.currentCorePayloadHashAlgorithm
        )

        // All authenticated payload mtimes changed after the cached scan. The
        // action context must rehash those changed objects, accept the unchanged
        // bytes, and retain a fresh descriptor-bound identity.
        let launchIdentity = try authenticatedContext
            .launchObjectIdentity(for: executable)
        let gstreamerPayload = root.appending(path: try XCTUnwrap(gstreamerPayloadPaths.first))
        let originalGStreamerPayload = try Data(contentsOf: gstreamerPayload)
        XCTAssertFalse(originalGStreamerPayload.isEmpty)
        var mutatedGStreamerPayload = originalGStreamerPayload
        mutatedGStreamerPayload[mutatedGStreamerPayload.startIndex] ^= 0x01
        let mutationDescriptor = Darwin.open(
            gstreamerPayload.path,
            O_WRONLY | O_CLOEXEC | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(mutationDescriptor, 0)
        guard mutationDescriptor >= 0 else { return }
        let mutationCount = mutatedGStreamerPayload.withUnsafeBytes { bytes in
            Darwin.pwrite(
                mutationDescriptor,
                bytes.baseAddress,
                bytes.count,
                0
            )
        }
        XCTAssertEqual(mutationCount, mutatedGStreamerPayload.count)
        XCTAssertEqual(Darwin.fsync(mutationDescriptor), 0)
        XCTAssertEqual(Darwin.close(mutationDescriptor), 0)
        XCTAssertThrowsError(try launchIdentity.revalidate())

        let restorationDescriptor = Darwin.open(
            gstreamerPayload.path,
            O_WRONLY | O_CLOEXEC | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(restorationDescriptor, 0)
        guard restorationDescriptor >= 0 else { return }
        let restorationCount = originalGStreamerPayload.withUnsafeBytes { bytes in
            Darwin.pwrite(
                restorationDescriptor,
                bytes.baseAddress,
                bytes.count,
                0
            )
        }
        XCTAssertEqual(restorationCount, originalGStreamerPayload.count)
        XCTAssertEqual(Darwin.fsync(restorationDescriptor), 0)
        XCTAssertEqual(Darwin.close(restorationDescriptor), 0)

        let wineInf = root.appending(path: "wine/share/wine/wine.inf")
        var tamperedWineInf = try Data(contentsOf: wineInf)
        tamperedWineInf.append(Data("tampered".utf8))
        try tamperedWineInf.write(to: wineInf)
        XCTAssertThrowsError(try launchIdentity.revalidate())
        XCTAssertThrowsError(try RuntimeManifestResolver().manifest(for: executable)) { error in
            guard case RuntimeManifestError.runtimePayloadFingerprintMismatch(let url) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, wineInf.standardizedFileURL.path)
        }
    }

    func testRuntimeAuthenticationCacheCoalescesConcurrentAndRepeatedRequests()
        async throws {
        let sourceRuntime = Self.repositoryRoot()
            .appending(
                path: "Resources/Runners/ForgePlayRuntime",
                directoryHint: .isDirectory
            )
        let executable = sourceRuntime.appending(path: "wine/bin/wine")
        let manifest = try JSONDecoder().decode(
            RuntimeManifest.self,
            from: Data(
                contentsOf: sourceRuntime.appending(
                    path: "RuntimeManifest.json"
                )
            )
        )
        let invocationCounter = RuntimeAuthenticationInvocationCounter()
        let cache = RuntimeAuthenticationCache { _ in
            invocationCounter.increment()
            Thread.sleep(forTimeInterval: 0.05)
            return RuntimeAuthenticatedContext(
                manifest: manifest,
                runtimeRoot: sourceRuntime
            )
        }

        async let first = cache.authenticatedContext(for: executable)
        async let second = cache.authenticatedContext(for: executable)
        async let third = cache.authenticatedContext(for: executable)
        let resolved = try await (first, second, third)
        let contexts = [resolved.0, resolved.1, resolved.2]
        let repeated = try await cache.authenticatedContext(for: executable)

        XCTAssertEqual(invocationCounter.value, 1)
        XCTAssertFalse(invocationCounter.wasInvokedOnMainThread)
        XCTAssertTrue(
            contexts.allSatisfy {
                $0.manifest.runnerBuildFingerprint ==
                    manifest.runnerBuildFingerprint
            }
        )
        XCTAssertEqual(
            repeated.manifest.runnerBuildFingerprint,
            manifest.runnerBuildFingerprint
        )
    }

    func testRuntimeManifestRejectsSBOMPayloadIdentityDrift() throws {
        let sourceRuntime = Self.repositoryRoot()
            .appending(path: "Resources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRuntimeSBOMIdentity-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        for relativePath in [
            "RuntimeManifest.json",
            "RuntimeSBOM.json",
            "wine/bin/wine",
            "wine/share/wine/wine.inf",
            "wine/lib/wine/x86_64-windows/wineboot.exe"
        ] {
            let source = sourceRuntime.appending(path: relativePath)
            let destination = root.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: destination)
        }

        let sbomURL = root.appending(path: "RuntimeSBOM.json")
        var sbom = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: sbomURL)) as? [String: Any]
        )
        sbom["payloadFingerprint"] = String(repeating: "0", count: 64)
        let alteredSBOM = try JSONSerialization.data(
            withJSONObject: sbom,
            options: [.prettyPrinted, .sortedKeys]
        ) + Data("\n".utf8)
        try alteredSBOM.write(to: sbomURL)
        let alteredSBOMSHA256 = SHA256.hash(data: alteredSBOM)
            .map { String(format: "%02x", $0) }
            .joined()

        let manifestURL = root.appending(path: "RuntimeManifest.json")
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        manifest["hostSupportSBOMSHA256"] = alteredSBOMSHA256
        let alteredManifest = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        ) + Data("\n".utf8)
        try alteredManifest.write(to: manifestURL)

        let executable = root.appending(path: "wine/bin/wine")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertThrowsError(try RuntimeManifestResolver().manifest(for: executable)) { error in
            guard case RuntimeManifestError.invalidManifest(_, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "host-support SBOM identity does not match the bundled manifest")
        }
    }

    func testDerivedRuntimeManifestNeverSubstitutesLauncherHashForMissingPayloads() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayDerivedRuntimeManifest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let wineRoot = root.appending(path: "wine", directoryHint: .isDirectory)
        let executable = wineRoot.appending(path: "bin/wine")
        let wineInf = wineRoot.appending(path: "share/wine/wine.inf")
        let wineboot = wineRoot.appending(path: "lib/wine/x86_64-windows/wineboot.exe")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        XCTAssertThrowsError(try RuntimeManifestResolver().manifest(for: executable)) { error in
            guard case RuntimeManifestError.runtimePayloadMissing(let url) = error else {
                return XCTFail("Unexpected strict identity error: \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, wineInf.standardizedFileURL.path)
        }
        let bothMissing = try RuntimeManifestResolver().diagnosticManifest(for: executable)
        XCTAssertEqual(bothMissing.identitySource, "derived")
        XCTAssertEqual(bothMissing.wineInfFingerprintState, "missing")
        XCTAssertEqual(bothMissing.winebootFingerprintState, "missing")
        XCTAssertNotEqual(bothMissing.wineInfSHA256, bothMissing.runnerLauncherSHA256)
        XCTAssertNotEqual(bothMissing.winebootSHA256, bothMissing.runnerLauncherSHA256)
        XCTAssertNotEqual(bothMissing.wineInfSHA256, bothMissing.winebootSHA256)
        XCTAssertEqual(bothMissing.identityIssues?.count, 2)

        try FileManager.default.createDirectory(
            at: wineInf.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "wine identity\n".write(to: wineInf, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RuntimeManifestResolver().manifest(for: executable)) { error in
            guard case RuntimeManifestError.runtimePayloadMissing(let url) = error else {
                return XCTFail("Unexpected strict identity error: \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, wineboot.standardizedFileURL.path)
        }
        let winebootMissing = try RuntimeManifestResolver().diagnosticManifest(for: executable)
        XCTAssertEqual(winebootMissing.wineInfFingerprintState, "verified")
        XCTAssertEqual(winebootMissing.winebootFingerprintState, "missing")
        XCTAssertEqual(winebootMissing.identityIssues?.count, 1)

        try FileManager.default.createDirectory(
            at: wineboot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "wineboot identity\n".write(to: wineboot, atomically: true, encoding: .utf8)
        let manifest = try RuntimeManifestResolver().manifest(for: executable)
        XCTAssertEqual(manifest.wineInfFingerprintState, "verified")
        XCTAssertEqual(manifest.winebootFingerprintState, "verified")
        XCTAssertTrue(manifest.identityIssues?.isEmpty == true)
        XCTAssertNotEqual(manifest.wineInfSHA256, manifest.runnerLauncherSHA256)
        XCTAssertNotEqual(manifest.winebootSHA256, manifest.runnerLauncherSHA256)

        try FileManager.default.removeItem(at: wineboot)
        try FileManager.default.createSymbolicLink(at: wineboot, withDestinationURL: wineInf)
        XCTAssertThrowsError(try RuntimeManifestResolver().manifest(for: executable)) { error in
            guard case RuntimeManifestError.unsafeRuntimePayload(let url) = error else {
                return XCTFail("Unexpected strict identity error: \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, wineboot.standardizedFileURL.path)
        }
        let unsafeWineboot = try RuntimeManifestResolver().diagnosticManifest(for: executable)
        XCTAssertEqual(unsafeWineboot.winebootFingerprintState, "unsafe")
        XCTAssertEqual(unsafeWineboot.identityIssues?.count, 1)
        XCTAssertNotEqual(unsafeWineboot.winebootSHA256, unsafeWineboot.runnerLauncherSHA256)

        try FileManager.default.removeItem(at: wineboot)
        try FileManager.default.linkItem(at: wineInf, to: wineboot)
        XCTAssertThrowsError(try RuntimeManifestResolver().manifest(for: executable)) { error in
            guard case RuntimeManifestError.unsafeRuntimePayload(let url) = error else {
                return XCTFail("Unexpected strict identity error: \(error)")
            }
            // A hard link makes both identities unsafe. Validation reads
            // wine.inf first, so it must reject that path before wineboot.
            XCTAssertEqual(url.standardizedFileURL.path, wineInf.standardizedFileURL.path)
        }
        let hardlinkedWineboot = try RuntimeManifestResolver().diagnosticManifest(for: executable)
        XCTAssertEqual(hardlinkedWineboot.wineInfFingerprintState, "unsafe")
        XCTAssertEqual(hardlinkedWineboot.winebootFingerprintState, "unsafe")
        XCTAssertEqual(hardlinkedWineboot.identityIssues?.count, 2)
        XCTAssertNotEqual(hardlinkedWineboot.winebootSHA256, hardlinkedWineboot.runnerLauncherSHA256)
    }

    func testRuntimeManifestReaderRejectsSymlinkAndHardlinkSources() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayUnsafeRuntimeManifest-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalManifest = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalRuntimeManifest-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalManifest)
        }

        let executable = root.appending(path: "wine/bin/wine")
        let manifest = root.appending(path: "wine/RuntimeManifest.json")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try "{}\n".write(to: externalManifest, atomically: true, encoding: .utf8)

        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: externalManifest)
        XCTAssertThrowsError(try RuntimeManifestResolver().manifest(for: executable)) { error in
            guard case RuntimeManifestError.unsafeManifest(let url) = error else {
                return XCTFail("Unexpected symlink manifest error: \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, manifest.standardizedFileURL.path)
        }

        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.linkItem(at: externalManifest, to: manifest)
        XCTAssertThrowsError(try RuntimeManifestResolver().manifest(for: executable)) { error in
            guard case RuntimeManifestError.unsafeManifest(let url) = error else {
                return XCTFail("Unexpected hardlink manifest error: \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, manifest.standardizedFileURL.path)
        }
    }

    func testSourceBundledRuntimeKeepsRendererEvidenceWithoutStaleSteamUIFailureMetadata() throws {
        let resourceRoot = Self.repositoryRoot()
            .appending(path: "Resources", directoryHint: .isDirectory)
        let executable = try ForgePlayBundledWindowsRuntimePolicy.requiredBundledRuntimeExecutable(
            inResourceRoot: resourceRoot
        )

        let capability = WindowsRuntimeService.inspectRuntimeCapability(for: executable)

        XCTAssertTrue(capability.supportsManagedSteamGameLaunches)
        XCTAssertTrue(capability.supportsWindowsSteamClientLaunches)
        XCTAssertTrue(capability.supportsSteamClientNetworking)
        XCTAssertTrue(capability.supportsModernDirect3DGames)
        XCTAssertEqual(capability.graphicsBackend, .d3dMetal)
        XCTAssertTrue(capability.evidence.contains("Frameworks/renderer/d9vk/wine/i386-windows/d3d9.dll"))
        XCTAssertTrue(capability.evidence.contains("Frameworks/renderer/d9vk/wine/x86_64-windows/d3d9.dll"))
        XCTAssertTrue(capability.evidence.contains("Frameworks/renderer/dxmt/wine/x86_64-unix/winemetal.so"))
        XCTAssertTrue(capability.evidence.contains("Frameworks/renderer/dxmt/wine/x86_64-windows/d3d11.dll"))
        XCTAssertTrue(capability.evidence.contains("Metal renderer window-surface contract export"))
        XCTAssertFalse(capability.limitations.contains("missing-dxmt-macdrv-metal-window-bridge"))
        XCTAssertFalse(capability.limitations.contains("steam-cef-child-window-metal-swapchain-unsupported"))
        XCTAssertFalse(capability.limitations.contains("active-d3dmetal-overlay-in-wine-modules"))
        XCTAssertFalse(capability.limitations.contains("missing-steam-cef-d3d9-renderer"))
        XCTAssertFalse(capability.limitations.contains("steam-cef-webhelper-renderer-validation-failed"))
        XCTAssertFalse(capability.limitations.contains("built-without-gnutls-or-schannel"))
        XCTAssertFalse(capability.limitations.contains("built-without-vulkan-or-d3dmetal"))
    }

    func testSourceBundledRuntimeRendererInspectionAllowsSteamProfileRepairDespiteUnvalidatedSteamCEFUI() throws {
        let resourceRoot = Self.repositoryRoot()
            .appending(path: "Resources", directoryHint: .isDirectory)
        let executable = try ForgePlayBundledWindowsRuntimePolicy.requiredBundledRuntimeExecutable(
            inResourceRoot: resourceRoot
        )
        let prefix = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayBundledRuntimeInspection-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: prefix) }

        let inspection = SteamRendererPolicyManager().inspect(
            prefix: prefix,
            runtimeExecutable: executable,
            selection: .d3dMetal
        )

        XCTAssertEqual(inspection.status, .warning)
        XCTAssertEqual(inspection.effectiveRecoveryKind, .applyPolicy)
        XCTAssertFalse(inspection.requiresRepair)
        XCTAssertFalse(inspection.requiresApply)
        XCTAssertTrue(inspection.allowsRecoveryAction)
        XCTAssertEqual(inspection.recoveryStatusLabelKey, "Steam 실행 경로 적용 필요")
        XCTAssertEqual(inspection.recoveryActionTitleKey, "실행 경로 적용/검증")
        XCTAssertTrue(
            inspection.userMessage.contains("Steam 프리픽스를 먼저 만들어야") ||
                inspection.userMessage.contains("Steam 실행 경로"),
            inspection.userMessage
        )
    }

    func testBundledRuntimeVerifierAcceptsConfiguredDirectDMGD3DMetalPayload() throws {
        let repositoryRoot = Self.repositoryRoot()
        let script = repositoryRoot.appending(path: "Scripts/verify-bundled-runtime-capability.sh")
        let resources = repositoryRoot.appending(path: "Resources", directoryHint: .isDirectory)
        var environment = ProcessInfo.processInfo.environment
        environment["FORGEPLAY_REQUIRE_DIRECT_DMG_RUNTIME"] = "1"

        let capture = try BoundedProcessExecutor.capture(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [script.path, resources.path],
            environment: environment,
            timeout: 300
        )
        let text = String(
            decoding: capture.stdout + capture.stderr,
            as: UTF8.self
        )
        XCTAssertTrue(capture.didExit)
        XCTAssertFalse(capture.didTimeOut)
        XCTAssertEqual(capture.exitCode, 0, text)
        XCTAssertTrue(
            text.contains("Bundled runtime capability verification passed"),
            text
        )
    }

    func testSourceBundledRuntimeKeepsDXVKPayloadButRejectsItsFailedDeviceGate() throws {
        let resourceRoot = Self.repositoryRoot()
            .appending(path: "Resources", directoryHint: .isDirectory)
        let executable = try ForgePlayBundledWindowsRuntimePolicy.requiredBundledRuntimeExecutable(
            inResourceRoot: resourceRoot
        )

        let capability = WindowsRuntimeService.inspectRuntimeCapability(for: executable)

        XCTAssertEqual(capability.graphicsBackend, .d3dMetal)
        XCTAssertTrue(capability.supportsD3DMetalBackend)
        XCTAssertTrue(capability.supportsVulkanBackend)
        XCTAssertTrue(capability.supportsDirect3D9Games)
        XCTAssertTrue(capability.supportsDirect3D11Games)
        XCTAssertTrue(capability.supportsDirect3D12Games)
        XCTAssertEqual(
            capability.supportedDirect3DGenerations(for: .d3dMetal),
            [.d3d11, .d3d12]
        )
        XCTAssertEqual(
            capability.supportedDirect3DGenerations(for: .moltenVKOrVulkan),
            [.d3d9]
        )
        XCTAssertEqual(
            SteamRendererPolicySelection.d3dMetal.resolvedLaunchPreference(capability: capability),
            .d3dMetal
        )
        XCTAssertEqual(
            SteamRendererPolicySelection.d3dMetalNVIDIA
                .resolvedLaunchPreference(capability: capability),
            .d3dMetal
        )
        XCTAssertNil(
            SteamRendererPolicySelection.vulkan
                .resolvedLaunchPreference(capability: capability)
        )
        guard let gate = capability.rendererRuntimeGate(for: .vulkan),
              case .failed(let evidence, let technicalDetail) = gate else {
            return XCTFail("Expected the locked DXVK generation to retain its failed gate")
        }
        XCTAssertTrue(evidence.contains("locked DXVK/MoltenVK"))
        XCTAssertTrue(technicalDetail.contains("geometryShader=0"))
        XCTAssertTrue(technicalDetail.contains("CreateDXGIFactory1"))
        XCTAssertTrue(
            capability.limitations.contains("dxvk-runtime-gate-failed")
        )
        XCTAssertEqual(
            SteamRendererPolicyPreference.vulkan
                .availability(in: capability)
                .userMessageLocalizationKey,
            SteamRendererPolicyPreference
                .dxvkRuntimeUnavailableLocalizationKey
        )
    }

    func testSourceBundledRuntimeKeepsEachManualRendererSelectionIsolated() throws {
        let resourceRoot = Self.repositoryRoot()
            .appending(path: "Resources", directoryHint: .isDirectory)
        let executable = try ForgePlayBundledWindowsRuntimePolicy.requiredBundledRuntimeExecutable(
            inResourceRoot: resourceRoot
        )

        let rendererByPolicy: [(SteamRendererPolicyPreference, String)] = [
            (.d3dMetal, "d3dmetal"),
            (.dxmt, "dxmt"),
            (.d9vk, "d9vk"),
            (.vulkan, "dxvk")
        ]
        let allRendererNames = Set(rendererByPolicy.map(\.1))

        for (policy, expectedRendererName) in rendererByPolicy {
            let modules = try SafeProcessRunner.rendererWindowsModuleFilesByWindowsDirectory(
                for: executable,
                graphicsBackend: policy
            )
            let paths = modules.values.flatMap { $0 }.map(\.standardizedFileURL.path)

            XCTAssertFalse(paths.isEmpty, "\(policy.rawValue) must resolve its exact payload")
            XCTAssertTrue(
                paths.allSatisfy { $0.contains("/renderer/\(expectedRendererName)/") },
                paths.joined(separator: "\n")
            )
            for forbiddenRendererName in allRendererNames.subtracting([expectedRendererName]) {
                XCTAssertFalse(
                    paths.contains { $0.contains("/renderer/\(forbiddenRendererName)/") },
                    "\(policy.rawValue) unexpectedly included \(forbiddenRendererName)"
                )
            }
        }
    }

    func testSourceBundledRuntimeBuildsProcessScopedRendererCompositionWithoutMutatingWindowsSystemDLLs() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayBundledRuntimePolicy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let resourceRoot = Self.repositoryRoot()
            .appending(path: "Resources", directoryHint: .isDirectory)
        let executable = try ForgePlayBundledWindowsRuntimePolicy.requiredBundledRuntimeExecutable(
            inResourceRoot: resourceRoot
        )
        let prefix = temporaryRoot.appending(path: "SteamShared", directoryHint: .isDirectory)
        let system32 = prefix.appending(path: "drive_c/windows/system32", directoryHint: .isDirectory)
        let syswow64 = prefix.appending(path: "drive_c/windows/syswow64", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syswow64, withIntermediateDirectories: true)
        try Data("original system32 d3d9".utf8).write(to: system32.appending(path: "d3d9.dll"))
        try Data("original system32 d3d11".utf8).write(to: system32.appending(path: "d3d11.dll"))
        try Data("original system32 dxgi".utf8).write(to: system32.appending(path: "dxgi.dll"))
        try Data("stale system32 winemetal".utf8).write(to: system32.appending(path: "winemetal.dll"))
        try Data("original syswow64 d3d9".utf8).write(to: syswow64.appending(path: "d3d9.dll"))
        try Data("original syswow64 d3d11".utf8).write(to: syswow64.appending(path: "d3d11.dll"))
        try Data("original syswow64 dxgi".utf8).write(to: syswow64.appending(path: "dxgi.dll"))
        try Data("stale syswow64 winemetal".utf8).write(to: syswow64.appending(path: "winemetal.dll"))

        let environment = try SafeProcessRunner.steamGameRendererPolicyEnvironment(
            for: executable,
            prefix: prefix,
            graphicsBackend: .d3dMetal,
            rendererSelection: .d3dMetalNVIDIA,
            logDirectory: temporaryRoot
        )

        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_POLICY_ENABLED"], "1")
        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_POLICY"], "d3dMetal")
        XCTAssertEqual(
            environment["FORGEPLAY_GAME_RENDERER_REQUESTED"],
            SteamRendererPolicySelection.d3dMetalNVIDIA.rawValue
        )
        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_COMPONENTS_X64"], "d3dmetal")
        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_COMPONENTS_X86"], "")
        XCTAssertTrue(
            environment["FORGEPLAY_GAME_RENDERER_DLL_PATH_X64"]?
                .contains("\\renderer\\d3dmetal\\") == true
        )
        XCTAssertFalse(
            environment["FORGEPLAY_GAME_RENDERER_DLL_PATH_X64"]?
                .contains("\\renderer\\d9vk\\") == true
        )
        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_DLL_PATH_X86"], "")
        XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_ENV_D3DM_WINE_UNIX_CALL"], "1")
        XCTAssertEqual(
            environment["FORGEPLAY_GAME_RENDERER_ENV_D3DM_ENABLE_METALFX"],
            "1"
        )
        let ngxDirectory = URL(
            fileURLWithPath: try XCTUnwrap(
                environment["FORGEPLAY_GAME_RENDERER_ENV_D3DM_NVNGX_PATH"]
            ),
            isDirectory: true
        )
        XCTAssertTrue(ngxDirectory.path.hasPrefix(prefix.path + "/.forgeplay/"))
        XCTAssertTrue(
            D3DMetalNGXBridgeContract.isUsable(
                at: ngxDirectory
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
            )
        )
        XCTAssertTrue(
            environment["FORGEPLAY_GAME_RENDERER_ENV_WINEDLLOVERRIDES"]?
                .contains("nvngx") == true
        )
        XCTAssertFalse(environment.keys.contains { $0.contains("_PROFILE_") })
        XCTAssertNil(environment["FORGEPLAY_GAME_RENDERER_ROUTING_MODE"])
        XCTAssertNil(environment["FORGEPLAY_GAME_RENDERER_AVAILABLE_PROFILES"])
        XCTAssertNil(environment["FORGEPLAY_GAME_RENDERER_UNAVAILABLE_PROFILES"])

        XCTAssertEqual(try String(contentsOf: system32.appending(path: "d3d9.dll"), encoding: .utf8), "original system32 d3d9")
        XCTAssertEqual(try String(contentsOf: system32.appending(path: "d3d11.dll"), encoding: .utf8), "original system32 d3d11")
        XCTAssertEqual(try String(contentsOf: system32.appending(path: "dxgi.dll"), encoding: .utf8), "original system32 dxgi")
        XCTAssertEqual(try String(contentsOf: system32.appending(path: "winemetal.dll"), encoding: .utf8), "stale system32 winemetal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: system32.appending(path: "d3d12.dll").path))
        XCTAssertEqual(try String(contentsOf: syswow64.appending(path: "d3d9.dll"), encoding: .utf8), "original syswow64 d3d9")
        XCTAssertEqual(try String(contentsOf: syswow64.appending(path: "d3d11.dll"), encoding: .utf8), "original syswow64 d3d11")
        XCTAssertEqual(try String(contentsOf: syswow64.appending(path: "dxgi.dll"), encoding: .utf8), "original syswow64 dxgi")
        XCTAssertEqual(try String(contentsOf: syswow64.appending(path: "winemetal.dll"), encoding: .utf8), "stale syswow64 winemetal")
    }

    func testSourceBundledRuntimeBuildsOnlyTheManuallySelectedRendererEnvironment() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayManualRendererPolicy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let resourceRoot = Self.repositoryRoot()
            .appending(path: "Resources", directoryHint: .isDirectory)
        let executable = try ForgePlayBundledWindowsRuntimePolicy.requiredBundledRuntimeExecutable(
            inResourceRoot: resourceRoot
        )
        let prefix = temporaryRoot.appending(path: "SteamShared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)

        let rendererByPolicy: [(SteamRendererPolicyPreference, String)] = [
            (.d3dMetal, "d3dmetal"),
            (.dxmt, "dxmt"),
            (.d9vk, "d9vk"),
            (.vulkan, "dxvk")
        ]
        let allRendererNames = Set(rendererByPolicy.map(\.1))

        for (policy, expectedRendererName) in rendererByPolicy {
            let environment = try SafeProcessRunner.steamGameRendererPolicyEnvironment(
                for: executable,
                prefix: prefix,
                graphicsBackend: policy,
                logDirectory: temporaryRoot
            )
            let environmentText = environment.values.joined(separator: "\n")

            XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_POLICY_ENABLED"], "1")
            XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_POLICY"], policy.rawValue)
            XCTAssertEqual(environment["FORGEPLAY_GAME_RENDERER_REQUESTED"], policy.rawValue)
            XCTAssertFalse(environment.keys.contains { $0.contains("_PROFILE_") })
            XCTAssertNil(environment["FORGEPLAY_GAME_RENDERER_ROUTING_MODE"])
            XCTAssertNil(environment["FORGEPLAY_GAME_RENDERER_AVAILABLE_PROFILES"])
            XCTAssertNil(environment["FORGEPLAY_GAME_RENDERER_UNAVAILABLE_PROFILES"])
            XCTAssertTrue(
                environmentText.contains("/renderer/\(expectedRendererName)/") ||
                    environmentText.contains("\\renderer\\\(expectedRendererName)\\"),
                environmentText
            )
            for forbiddenRendererName in allRendererNames.subtracting([expectedRendererName]) {
                XCTAssertFalse(
                    environmentText.contains("/renderer/\(forbiddenRendererName)/") ||
                        environmentText.contains("\\renderer\\\(forbiddenRendererName)\\"),
                    "\(policy.rawValue) unexpectedly included \(forbiddenRendererName)"
                )
            }
        }
    }

    func testSourceBundledRuntimeEntrypointsPreserveRendererDLLPrecedence() throws {
        let runtimeRoot = Self.repositoryRoot()
            .appending(path: "Resources/Runners/ForgePlayRuntime", directoryHint: .isDirectory)

        for launcherName in ["wine", "wineserver"] {
            let launcher = runtimeRoot.appending(path: "wine/bin/\(launcherName)")
            let script = try String(contentsOf: launcher, encoding: .utf8)
            XCTAssertFalse(
                script.contains("export WINEDLLPATH=\"$(prepend_path \"$WINE_ROOT/lib/wine"),
                "\(launcherName) must not put base Wine DLL directories before renderer DLL directories"
            )
            XCTAssertTrue(
                script.contains("export WINEDLLPATH=\"$(append_path \"$WINE_ROOT/lib/wine:$WINE_ROOT/lib/wine/x86_64-unix"),
                "\(launcherName) must preserve renderer WINEDLLPATH before appending base Wine DLL directories"
            )
            XCTAssertTrue(
                script.contains("BASE_LIBS=\"$WINE_ROOT/lib:$WINE_ROOT/lib/wine/x86_64-unix:$WINE_ROOT/lib/wine/i386-unix\""),
                "\(launcherName) must load the complete pinned dependency closure from wine/lib"
            )
            XCTAssertFalse(
                script.contains("$RUNTIME_ROOT/Frameworks"),
                "\(launcherName) must not expose unrelated host libraries through a Frameworks fallback path"
            )
        }
        let wineLauncher = try String(
            contentsOf: runtimeRoot.appending(path: "wine/bin/wine"),
            encoding: .utf8
        )
        XCTAssertTrue(
            wineLauncher.contains("exec \"$WINE_ROOT/lib/wine/x86_64-unix/wine\" \"$@\""),
            "The installed Wine loader must run from the directory that also contains ntdll.so"
        )
    }

    func testFindsBundledWineRunnerUnderResourcesRunners() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayBundledRunner-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let bin = root
            .appending(path: "Runners/ForgePlayRuntime/wine/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let wine = bin.appending(path: "wine")
        try "#!/bin/sh\nexit 0\n".write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)

        let result = ForgePlayBundledWindowsRuntimePolicy.findBundledRuntimeExecutable(inResourceRoot: root)

        XCTAssertEqual(result?.standardizedFileURL.path, wine.standardizedFileURL.path)
        XCTAssertEqual(
            try ForgePlayBundledWindowsRuntimePolicy.requiredBundledRuntimeExecutable(inResourceRoot: root)
                .standardizedFileURL.path,
            wine.standardizedFileURL.path
        )
        XCTAssertTrue(ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable(wine, inResourceRoot: root))
    }

    func testInjectedBundleLookupObservesCurrentFixtureInsteadOfProcessSnapshot() throws {
        let bundleRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlayBundledRunnerFixture-\(UUID().uuidString).bundle",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: bundleRoot) }

        let contents = bundleRoot.appending(path: "Contents", directoryHint: .isDirectory)
        let resources = contents.appending(path: "Resources", directoryHint: .isDirectory)
        let bin = resources.appending(
            path: "Runners/ForgePlayRuntime/wine/bin",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "dev.forgeplay.runtime-fixture.\(UUID().uuidString)",
                "CFBundleName": "ForgePlay Runtime Fixture",
                "CFBundlePackageType": "BNDL",
                "CFBundleVersion": "1"
            ],
            format: .xml,
            options: 0
        )
        try info.write(to: contents.appending(path: "Info.plist"))

        let wine = bin.appending(path: "wine")
        try "#!/bin/sh\nexit 0\n".write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: wine.path
        )
        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))

        XCTAssertEqual(
            ForgePlayBundledWindowsRuntimePolicy.bundledRuntimeExecutableURL(
                bundle: bundle
            )?.standardizedFileURL.path,
            wine.standardizedFileURL.path
        )

        try FileManager.default.removeItem(at: wine)

        XCTAssertNil(
            ForgePlayBundledWindowsRuntimePolicy.bundledRuntimeExecutableURL(
                bundle: bundle
            )
        )
    }

    func testRequiredBundledRunnerReportsMissingRunnerDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayBundledRunnerMissing-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertNil(ForgePlayBundledWindowsRuntimePolicy.findBundledRuntimeExecutable(inResourceRoot: root))
        XCTAssertThrowsError(
            try ForgePlayBundledWindowsRuntimePolicy.requiredBundledRuntimeExecutable(inResourceRoot: root)
        ) { error in
            guard case ForgePlayBundledWindowsRuntimePolicyError.runtimeContainerUnavailable(let url, _) = error else {
                return XCTFail("Expected runtimeContainerUnavailable, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, root.appending(path: "Runners").standardizedFileURL.path)
        }
    }

    func testRequiredBundledRunnerReportsWhenOnlyUnsafeCandidatesExist() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayBundledRunnerUnsafeOnly-\(UUID().uuidString)", directoryHint: .isDirectory)
        let external = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayBundledRunnerUnsafeOnlyExternal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }

        let runnerBin = root.appending(path: "Runners/ForgePlayRuntime/wine/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runnerBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

        let externalWine = external.appending(path: "wine")
        try "#!/bin/sh\nexit 0\n".write(to: externalWine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: externalWine.path)
        try FileManager.default.createSymbolicLink(
            at: runnerBin.appending(path: "wine"),
            withDestinationURL: externalWine
        )

        XCTAssertNil(ForgePlayBundledWindowsRuntimePolicy.findBundledRuntimeExecutable(inResourceRoot: root))
        XCTAssertThrowsError(
            try ForgePlayBundledWindowsRuntimePolicy.requiredBundledRuntimeExecutable(inResourceRoot: root)
        ) { error in
            guard case ForgePlayBundledWindowsRuntimePolicyError.runtimeExecutableUnavailable(let url) = error else {
                return XCTFail("Expected runtimeExecutableUnavailable, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, root.appending(path: "Runners").standardizedFileURL.path)
        }
    }

    func testRejectsSymlinkAndHardlinkedBundledRunnerCandidates() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayBundledRunnerLinks-\(UUID().uuidString)", directoryHint: .isDirectory)
        let external = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayBundledRunnerExternal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }

        let runnerBin = root.appending(path: "Runners/ForgePlayRuntime/wine/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runnerBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

        let externalWine = external.appending(path: "wine")
        try "#!/bin/sh\nexit 0\n".write(to: externalWine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: externalWine.path)
        let linkedWine = runnerBin.appending(path: "wine")
        try FileManager.default.createSymbolicLink(at: linkedWine, withDestinationURL: externalWine)

        XCTAssertNil(ForgePlayBundledWindowsRuntimePolicy.findBundledRuntimeExecutable(inResourceRoot: root))
        XCTAssertFalse(ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable(linkedWine, inResourceRoot: root))

        try FileManager.default.removeItem(at: linkedWine)
        let hardlinkSource = external.appending(path: "hardlink-source")
        try "#!/bin/sh\nexit 0\n".write(to: hardlinkSource, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hardlinkSource.path)
        let hardlinkedWine = runnerBin.appending(path: "wine")
        try FileManager.default.linkItem(at: hardlinkSource, to: hardlinkedWine)

        XCTAssertNil(ForgePlayBundledWindowsRuntimePolicy.findBundledRuntimeExecutable(inResourceRoot: root))
        XCTAssertFalse(ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable(hardlinkedWine, inResourceRoot: root))
    }

    func testRejectsRunnerThroughSymlinkedParentDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayBundledRunnerParentLink-\(UUID().uuidString)", directoryHint: .isDirectory)
        let external = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayBundledRunnerParentExternal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }

        let runnersRoot = root.appending(path: "Runners", directoryHint: .isDirectory)
        let externalBin = external.appending(path: "wine/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runnersRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalBin, withIntermediateDirectories: true)

        let externalWine = externalBin.appending(path: "wine")
        try "#!/bin/sh\nexit 0\n".write(to: externalWine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: externalWine.path)

        let linkedRuntime = runnersRoot.appending(path: "ForgePlayRuntime", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: linkedRuntime, withDestinationURL: external)
        let candidate = linkedRuntime.appending(path: "wine/bin/wine")

        XCTAssertNil(ForgePlayBundledWindowsRuntimePolicy.findBundledRuntimeExecutable(inResourceRoot: root))
        XCTAssertFalse(ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable(candidate, inResourceRoot: root))
    }

    private static func repositoryRoot(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func binary(_ url: URL, contains marker: String) throws -> Bool {
        try Data(contentsOf: url).range(of: Data(marker.utf8)) != nil
    }

    private static func exportedSymbols(_ url: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        process.arguments = ["-gU", url.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "BundledWindowsRuntimePolicyTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }
        return output
    }
}
