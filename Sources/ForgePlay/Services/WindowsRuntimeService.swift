import CryptoKit
import Darwin
import Foundation
import Security

protocol AppleStaticCodeValidating: Sendable {
    func validate(
        codeAt url: URL,
        requirement: String,
        validatesNestedCode: Bool
    ) throws
}

struct SecurityFrameworkAppleStaticCodeValidator: AppleStaticCodeValidating {
    func validate(
        codeAt url: URL,
        requirement: String,
        validatesNestedCode: Bool
    ) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw AppleSupplementalRendererAuthenticationError
                .signatureRejected(url, createStatus)
        }

        var codeRequirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirement as CFString,
            SecCSFlags(),
            &codeRequirement
        )
        guard requirementStatus == errSecSuccess,
              let codeRequirement else {
            throw AppleSupplementalRendererAuthenticationError
                .invalidRequirement(requirement, requirementStatus)
        }

        var rawFlags = kSecCSStrictValidate | kSecCSCheckAllArchitectures
        if validatesNestedCode {
            rawFlags |= kSecCSCheckNestedCode
        }
        let validationStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: rawFlags),
            codeRequirement
        )
        guard validationStatus == errSecSuccess else {
            throw AppleSupplementalRendererAuthenticationError
                .signatureRejected(url, validationStatus)
        }
    }
}

protocol AppleSupplementalRendererAuthenticating: Sendable {
    func authenticate(
        rendererRoot: URL,
        fileManager: FileManager
    ) throws
}

enum AppleSupplementalRendererAuthenticationError: LocalizedError {
    case missingExpectedNativeCode(URL)
    case unlistedNativeCode(URL)
    case invalidRequirement(String, OSStatus)
    case signatureRejected(URL, OSStatus)
    case scanFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .missingExpectedNativeCode(let url):
            return "Apple D3DMetal 보조 렌더러의 필수 native code가 없거나 안전하지 않습니다: \(url.path)"
        case .unlistedNativeCode(let url):
            return "Apple D3DMetal 보조 렌더러에 허용되지 않은 native code가 포함되어 있습니다: \(url.path)"
        case .invalidRequirement(let requirement, let status):
            return "Apple 코드 서명 requirement를 구성하지 못했습니다(\(status)): \(requirement)"
        case .signatureRejected(let url, let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ??
                "OSStatus \(status)"
            return "Apple이 서명한 D3DMetal 코드인지 확인하지 못했습니다: \(url.path). \(detail)"
        case .scanFailed(let root, let error):
            return "Apple D3DMetal 보조 렌더러의 native code를 검사하지 못했습니다: \(root.path). \(forgePlayTechnicalErrorSummary(error))"
        }
    }
}

/// Authenticates every host-native object that a managed Apple D3DMetal
/// renderer can place on Wine's DYLD search path. Windows PE modules and data
/// remain structure-checked, while the complete Mach-O set is closed to these
/// six Apple-signed objects and their pinned designated identifiers.
struct AppleSupplementalRendererTrustPolicy: AppleSupplementalRendererAuthenticating {
    struct NativeCodeRequirement: Hashable, Sendable {
        let relativePath: String
        let identifier: String

        var requirement: String {
            "identifier \"\(identifier)\" and anchor apple"
        }
    }

    static let nativeCodeRequirements = [
        NativeCodeRequirement(
            relativePath: "external/D3DMetal.framework/D3DMetal",
            identifier: "com.apple.D3DMetal"
        ),
        NativeCodeRequirement(
            relativePath: "external/libd3dshared.dylib",
            identifier: "com.apple.libd3dshared"
        ),
        NativeCodeRequirement(
            relativePath: "external/D3DMetal.framework/Resources/libdxccontainer.dylib",
            identifier: "libdxccontainer-555549444898ba00ad1839edb58895783e058678"
        ),
        NativeCodeRequirement(
            relativePath: "external/D3DMetal.framework/Resources/libdxcompiler.dylib",
            identifier: "com.apple.libdxcompiler"
        ),
        NativeCodeRequirement(
            relativePath: "external/D3DMetal.framework/Resources/libdxilconv.dylib",
            identifier: "com.apple.libdxilconv"
        ),
        NativeCodeRequirement(
            relativePath: "external/D3DMetal.framework/Resources/libmetalirconverter.dylib",
            identifier: "com.apple.libmetalirconverter"
        )
    ]

    private let staticCodeValidator: any AppleStaticCodeValidating

    init(
        staticCodeValidator: any AppleStaticCodeValidating =
            SecurityFrameworkAppleStaticCodeValidator()
    ) {
        self.staticCodeValidator = staticCodeValidator
    }

    func authenticate(
        rendererRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        let normalizedRoot = rendererRoot.standardizedFileURL
        do {
            try WindowsRuntimeService.validateSupplementalRedistLinks(
                in: normalizedRoot,
                fileManager: fileManager
            )
        } catch let error as WindowsRuntimeServiceError {
            throw error
        } catch {
            throw AppleSupplementalRendererAuthenticationError
                .scanFailed(normalizedRoot, error)
        }

        var allowedNativeCodePaths = Set<String>()
        for entry in Self.nativeCodeRequirements {
            let candidate = normalizedRoot.appending(path: entry.relativePath)
            guard D3DMetalRendererPayloadContract.isSafePayloadPath(
                entry.relativePath,
                at: normalizedRoot,
                fileManager: fileManager
            ) else {
                throw AppleSupplementalRendererAuthenticationError
                    .missingExpectedNativeCode(candidate)
            }
            let isMachO: Bool
            do {
                isMachO = try Self.isMachO(candidate)
            } catch {
                throw AppleSupplementalRendererAuthenticationError
                    .scanFailed(candidate, error)
            }
            guard isMachO else {
                throw AppleSupplementalRendererAuthenticationError
                    .missingExpectedNativeCode(candidate)
            }
            allowedNativeCodePaths.insert(
                candidate.resolvingSymlinksInPath().standardizedFileURL.path
            )
        }

        let framework = normalizedRoot.appending(
            path: "external/D3DMetal.framework",
            directoryHint: .isDirectory
        )
        try staticCodeValidator.validate(
            codeAt: framework,
            requirement: Self.nativeCodeRequirements[0].requirement,
            validatesNestedCode: true
        )
        for entry in Self.nativeCodeRequirements {
            try staticCodeValidator.validate(
                codeAt: normalizedRoot.appending(path: entry.relativePath),
                requirement: entry.requirement,
                validatesNestedCode: false
            )
        }

        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: normalizedRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw AppleSupplementalRendererAuthenticationError
                .scanFailed(normalizedRoot, CocoaError(.fileReadUnknown))
        }

        do {
            for case let item as URL in enumerator {
                let values = try item.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ])
                if values.isSymbolicLink == true {
                    if values.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true,
                      try Self.isMachO(item) else {
                    continue
                }
                let resolvedPath = item.resolvingSymlinksInPath()
                    .standardizedFileURL.path
                guard allowedNativeCodePaths.contains(resolvedPath) else {
                    throw AppleSupplementalRendererAuthenticationError
                        .unlistedNativeCode(item)
                }
            }
        } catch let authenticationError as
            AppleSupplementalRendererAuthenticationError {
            throw authenticationError
        } catch {
            throw AppleSupplementalRendererAuthenticationError
                .scanFailed(normalizedRoot, error)
        }
        if let enumerationError {
            throw AppleSupplementalRendererAuthenticationError
                .scanFailed(normalizedRoot, enumerationError)
        }
    }

    private static func isMachO(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 4) ?? Data()
        guard magic.count == 4 else {
            return false
        }
        let bytes = Array(magic)
        return [
            [0xfe, 0xed, 0xfa, 0xce],
            [0xce, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xcf],
            [0xcf, 0xfa, 0xed, 0xfe],
            [0xca, 0xfe, 0xba, 0xbe],
            [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf],
            [0xbf, 0xba, 0xfe, 0xca]
        ].contains(bytes)
    }
}

enum D3DMetalRendererPayloadContract {
    enum LaunchScope: String, Sendable {
        /// D3D10 and D3D11 share one routing family in ForgePlay.
        case direct3D11Family
        case direct3D12
        /// Complete cross-generation closure used by compatibility inspection.
        case mixed
    }

    nonisolated static let sharedLibraryRelativePath = "external/libd3dshared.dylib"
    nonisolated static let sharedUnixModuleLinkTarget = "../../external/libd3dshared.dylib"
    private nonisolated static let frameworkRelativePath = "external/D3DMetal.framework"
    private nonisolated static let frameworkExecutableRelativePath =
        "external/D3DMetal.framework/D3DMetal"
    private nonisolated static let frameworkResourcesRelativePath =
        "external/D3DMetal.framework/Resources"
    nonisolated static let sharedUnixModuleRelativePaths = [
        "wine/x86_64-unix/d3d10.so",
        "wine/x86_64-unix/d3d11.so",
        "wine/x86_64-unix/d3d12.so",
        "wine/x86_64-unix/dxgi.so",
        "wine/x86_64-unix/nvapi.so",
        "wine/x86_64-unix/nvapi64.so",
        "wine/x86_64-unix/nvngx-on-metalfx.so"
    ]

    nonisolated static let direct3D11ClosureRelativePaths = [
        "external/D3DMetal.framework/D3DMetal",
        "external/libd3dshared.dylib",
        "wine/x86_64-unix/d3d10.so",
        "wine/x86_64-unix/d3d11.so",
        "wine/x86_64-unix/dxgi.so",
        "wine/x86_64-windows/d3d10.dll",
        "wine/x86_64-windows/d3d11.dll",
        "wine/x86_64-windows/dxgi.dll"
    ]

    nonisolated static let direct3D12ClosureRelativePaths = [
        "external/D3DMetal.framework/D3DMetal",
        "external/D3DMetal.framework/Resources/Info.plist",
        "external/D3DMetal.framework/Resources/default.metallib",
        "external/D3DMetal.framework/Resources/libdxccontainer.dylib",
        "external/D3DMetal.framework/Resources/libdxcompiler.dylib",
        "external/D3DMetal.framework/Resources/libdxilconv.dylib",
        "external/D3DMetal.framework/Resources/libmetalirconverter.dylib",
        "external/libd3dshared.dylib",
        // A process that selects D3D12 may still load D3D11/D3D10 companion
        // modules. Keep the highest-generation route inside one verified
        // renderer root instead of allowing a second renderer to leak in.
        "wine/x86_64-unix/d3d10.so",
        "wine/x86_64-unix/d3d11.so",
        "wine/x86_64-unix/d3d12.so",
        "wine/x86_64-unix/dxgi.so",
        "wine/x86_64-windows/d3d10.dll",
        "wine/x86_64-windows/d3d11.dll",
        "wine/x86_64-windows/d3d12.dll",
        "wine/x86_64-windows/dxgi.dll"
    ]

    /// Provider-only payload used by the explicit D3DMetal NVIDIA selection.
    /// Standard D3DMetal must remain usable without advertising or loading any
    /// NVAPI/NGX module.
    nonisolated static let nvidiaMetalFXClosureRelativePaths = [
        "wine/x86_64-unix/nvapi.so",
        "wine/x86_64-unix/nvapi64.so",
        "wine/x86_64-unix/nvngx-on-metalfx.so",
        "wine/x86_64-windows/nvapi.dll",
        "wine/x86_64-windows/nvapi64.dll",
        "wine/x86_64-windows/nvngx-on-metalfx.dll"
    ]

    nonisolated static func requiredRelativePaths(for scope: LaunchScope) -> [String] {
        switch scope {
        case .direct3D11Family:
            direct3D11ClosureRelativePaths
        case .direct3D12:
            direct3D12ClosureRelativePaths
        case .mixed:
            Array(Set(direct3D11ClosureRelativePaths + direct3D12ClosureRelativePaths)).sorted()
        }
    }

    /// Validate only the closure that the Wine route will advertise. Each Unix
    /// module link is checked individually by `isSafePayloadPath`; requiring the
    /// unrelated D3D12/NVAPI links here would make a valid D3D11 route disappear.
    nonisolated static func isUsable(
        for scope: LaunchScope,
        at rendererRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard requiredRelativePaths(for: scope).allSatisfy({
            isSafePayloadPath($0, at: rendererRoot, fileManager: fileManager)
        }) else {
            return false
        }
        return scope != .direct3D12 || hasDirect3D12FrameworkMetadata(
            at: rendererRoot,
            fileManager: fileManager
        )
    }

    nonisolated static func hasValidSharedUnixModuleLinks(
        at rendererRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        isUsable(for: .mixed, at: rendererRoot, fileManager: fileManager) &&
            isNVIDIAMetalFXUsable(
                at: rendererRoot,
                fileManager: fileManager
            )
    }

    nonisolated static func isNVIDIAMetalFXUsable(
        at rendererRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        nvidiaMetalFXClosureRelativePaths.allSatisfy {
            isSafePayloadPath(
                $0,
                at: rendererRoot,
                fileManager: fileManager
            )
        } && D3DMetalNVAPIAliasContract.isUsable(
            at: rendererRoot,
            fileManager: fileManager
        )
    }

    nonisolated static func isSafePayloadPath(
        _ relativePath: String,
        at rendererRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let candidate = rendererRoot.appending(path: relativePath)
        if sharedUnixModuleRelativePaths.contains(relativePath) {
            let sharedLibrary = rendererRoot.appending(path: sharedLibraryRelativePath)
            guard isSafeRegularPayloadFile(
                sharedLibrary,
                under: rendererRoot,
                fileManager: fileManager
            ) else {
                return false
            }
            return isExpectedSharedUnixModuleLink(
                candidate,
                relativePath: relativePath,
                rendererRoot: rendererRoot,
                sharedLibrary: sharedLibrary,
                fileManager: fileManager
            )
        }
        if relativePath == frameworkExecutableRelativePath ||
            relativePath.hasPrefix("\(frameworkResourcesRelativePath)/") {
            if isSafeRegularPayloadFile(candidate, under: rendererRoot, fileManager: fileManager) {
                return true
            }
            return isCanonicalAppleFrameworkPayloadPath(
                relativePath,
                at: rendererRoot,
                fileManager: fileManager
            )
        }
        return isSafeRegularPayloadFile(candidate, under: rendererRoot, fileManager: fileManager)
    }

    /// Apple's signed D3DMetal framework uses the standard versioned framework
    /// layout. The public executable and Resources entries are internal
    /// symlinks, and replacing them with copied files invalidates Apple's
    /// CodeResources seal. Accept only that exact, self-contained link graph;
    /// every resolved payload still has to be a single-link regular file under
    /// Versions/A.
    private nonisolated static func isCanonicalAppleFrameworkPayloadPath(
        _ relativePath: String,
        at rendererRoot: URL,
        fileManager: FileManager
    ) -> Bool {
        let framework = rendererRoot.appending(path: frameworkRelativePath, directoryHint: .isDirectory)
        let versions = framework.appending(path: "Versions", directoryHint: .isDirectory)
        let versionA = versions.appending(path: "A", directoryHint: .isDirectory)
        let current = versions.appending(path: "Current", directoryHint: .isDirectory)
        let executableLink = framework.appending(path: "D3DMetal")
        let resourcesLink = framework.appending(path: "Resources", directoryHint: .isDirectory)

        guard FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
            from: rendererRoot,
            to: framework,
            fileManager: fileManager
        ),
        FileSystemItemPolicy.isNonSymlinkDirectory(framework, fileManager: fileManager),
        FileSystemItemPolicy.isNonSymlinkDirectory(versions, fileManager: fileManager),
        FileSystemItemPolicy.isNonSymlinkDirectory(versionA, fileManager: fileManager),
        isExpectedFrameworkSymlink(
            current,
            destination: "A",
            resolvedTarget: versionA,
            fileManager: fileManager
        ),
        isExpectedFrameworkSymlink(
            executableLink,
            destination: "Versions/Current/D3DMetal",
            resolvedTarget: versionA.appending(path: "D3DMetal"),
            fileManager: fileManager
        ),
        isExpectedFrameworkSymlink(
            resourcesLink,
            destination: "Versions/Current/Resources",
            resolvedTarget: versionA.appending(path: "Resources", directoryHint: .isDirectory),
            fileManager: fileManager
        ) else {
            return false
        }

        let expectedResolvedPayload: URL
        if relativePath == frameworkExecutableRelativePath {
            expectedResolvedPayload = versionA.appending(path: "D3DMetal")
        } else {
            let resourceRelativePath = String(
                relativePath.dropFirst("\(frameworkResourcesRelativePath)/".count)
            )
            guard !resourceRelativePath.isEmpty,
                  !resourceRelativePath.hasPrefix("/"),
                  !resourceRelativePath.split(separator: "/").contains(where: {
                      $0.isEmpty || $0 == "." || $0 == ".."
                  }) else {
                return false
            }
            expectedResolvedPayload = versionA
                .appending(path: "Resources", directoryHint: .isDirectory)
                .appending(path: resourceRelativePath)
        }

        let requestedPayload = rendererRoot.appending(path: relativePath)
        guard requestedPayload.resolvingSymlinksInPath().standardizedFileURL ==
                expectedResolvedPayload.standardizedFileURL,
              FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                from: versionA,
                to: expectedResolvedPayload,
                fileManager: fileManager
              ),
              FileSystemItemPolicy.isRegularNonSymlinkFile(
                expectedResolvedPayload,
                fileManager: fileManager
              ) else {
            return false
        }
        return true
    }

    private nonisolated static func isExpectedFrameworkSymlink(
        _ link: URL,
        destination: String,
        resolvedTarget: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let values = try? link.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink == true,
              let actualDestination = try? fileManager.destinationOfSymbolicLink(atPath: link.path),
              actualDestination == destination else {
            return false
        }
        return link.resolvingSymlinksInPath().standardizedFileURL ==
            resolvedTarget.standardizedFileURL
    }

    private nonisolated static func hasDirect3D12FrameworkMetadata(
        at rendererRoot: URL,
        fileManager: FileManager
    ) -> Bool {
        let infoPlist = rendererRoot.appending(
            path: "external/D3DMetal.framework/Resources/Info.plist"
        )
        guard isSafePayloadPath(
            "external/D3DMetal.framework/Resources/Info.plist",
            at: rendererRoot,
            fileManager: fileManager
        ),
        let data = try? Data(contentsOf: infoPlist, options: .mappedIfSafe),
        let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ),
        let dictionary = plist as? [String: Any],
        dictionary["CFBundleExecutable"] as? String == "D3DMetal",
        let shortVersion = (dictionary["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        let bundleVersion = (dictionary["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !bundleVersion.isEmpty,
        let majorVersion = Int(shortVersion.prefix(while: \Character.isNumber)),
        majorVersion >= 4 else {
            return false
        }
        return true
    }

    private nonisolated static func isExpectedSharedUnixModuleLink(
        _ candidate: URL,
        relativePath: String,
        rendererRoot: URL,
        sharedLibrary: URL,
        fileManager: FileManager
    ) -> Bool {
        guard sharedUnixModuleRelativePaths.contains(relativePath),
              FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                from: rendererRoot,
                to: candidate,
                fileManager: fileManager
              ),
              let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink == true,
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: candidate.path),
              destination == sharedUnixModuleLinkTarget,
              candidate.resolvingSymlinksInPath().standardizedFileURL ==
                sharedLibrary.standardizedFileURL else {
            return false
        }
        return true
    }

    private nonisolated static func isSafeRegularPayloadFile(
        _ candidate: URL,
        under rendererRoot: URL,
        fileManager: FileManager
    ) -> Bool {
        FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
            from: rendererRoot,
            to: candidate,
            fileManager: fileManager
        ) && FileSystemItemPolicy.isRegularNonSymlinkFile(candidate, fileManager: fileManager)
    }
}

/// Verifies the two derived aliases required by Apple's 64-bit NVAPI module.
/// The PE module identifies itself internally as `nvapi.dll`, while games and
/// Streamline normally request `nvapi64.dll`. Both names must resolve to the
/// same PE bytes and the same canonical D3DMetal Unix implementation.
enum D3DMetalNVAPIAliasContract {
    nonisolated static let sourceWindowsModuleRelativePath =
        "wine/x86_64-windows/nvapi64.dll"
    nonisolated static let windowsAliasRelativePath =
        "wine/x86_64-windows/nvapi.dll"
    nonisolated static let unixAliasRelativePath =
        "wine/x86_64-unix/nvapi.so"
    nonisolated static let sharedLibraryRelativePath =
        D3DMetalRendererPayloadContract.sharedLibraryRelativePath
    nonisolated static let sharedUnixModuleLinkTarget =
        D3DMetalRendererPayloadContract.sharedUnixModuleLinkTarget

    nonisolated static func isUsable(
        at rendererRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let sourceWindowsModule = rendererRoot.appending(
            path: sourceWindowsModuleRelativePath
        )
        let windowsAlias = rendererRoot.appending(
            path: windowsAliasRelativePath
        )
        let unixAlias = rendererRoot.appending(path: unixAliasRelativePath)
        let sharedLibrary = rendererRoot.appending(
            path: sharedLibraryRelativePath
        )

        guard FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
            from: rendererRoot,
            to: sourceWindowsModule,
            fileManager: fileManager
        ),
        FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
            from: rendererRoot,
            to: windowsAlias,
            fileManager: fileManager
        ),
        FileSystemItemPolicy.isRegularNonSymlinkFile(
            sourceWindowsModule,
            fileManager: fileManager
        ),
        FileSystemItemPolicy.isRegularNonSymlinkFile(
            windowsAlias,
            fileManager: fileManager
        ),
        fileManager.contentsEqual(
            atPath: sourceWindowsModule.path,
            andPath: windowsAlias.path
        ),
        let aliasValues = try? unixAlias.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ),
        aliasValues.isSymbolicLink == true,
        let destination = try? fileManager.destinationOfSymbolicLink(
            atPath: unixAlias.path
        ),
        destination == sharedUnixModuleLinkTarget,
        unixAlias.resolvingSymlinksInPath().standardizedFileURL ==
            sharedLibrary.standardizedFileURL else {
            return false
        }
        return true
    }
}

/// Materializes the exact filename pair expected by Apple's public MetalFX
/// bridge without modifying the signed/locked D3DMetal payload. The derived
/// files live in the selected Wine prefix so each launch remains isolated from
/// Steam infrastructure and from other prefixes.
enum D3DMetalNGXBridgeContract {
    nonisolated static let sourceWindowsModuleRelativePath =
        "wine/x86_64-windows/nvngx-on-metalfx.dll"
    nonisolated static let windowsModuleRelativePath =
        "wine/x86_64-windows/nvngx.dll"
    nonisolated static let unixModuleRelativePath =
        "wine/x86_64-unix/nvngx.so"
    nonisolated static let sharedLibraryRelativePath =
        "external/libd3dshared.dylib"
    nonisolated static let sharedUnixModuleLinkTarget =
        "../../external/libd3dshared.dylib"

    nonisolated static func materialize(
        from rendererRoot: URL,
        in prefix: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try FileSystemItemPolicy.requireNonSymlinkDirectory(
            prefix,
            fileManager: fileManager
        )
        guard D3DMetalRendererPayloadContract.isSafePayloadPath(
            sourceWindowsModuleRelativePath,
            at: rendererRoot,
            fileManager: fileManager
        ),
        D3DMetalRendererPayloadContract.isSafePayloadPath(
            D3DMetalRendererPayloadContract.sharedLibraryRelativePath,
            at: rendererRoot,
            fileManager: fileManager
        ) else {
            throw FileSystemItemPolicyError.notRegularNonSymlinkFile(
                rendererRoot.appending(path: sourceWindowsModuleRelativePath)
            )
        }

        let sourceWindowsModule = rendererRoot.appending(
            path: sourceWindowsModuleRelativePath
        )
        let sourceSharedLibrary = rendererRoot.appending(
            path: D3DMetalRendererPayloadContract.sharedLibraryRelativePath
        )
        let windowsModuleData = try Data(
            contentsOf: sourceWindowsModule,
            options: .mappedIfSafe
        )
        let sharedLibraryData = try Data(
            contentsOf: sourceSharedLibrary,
            options: .mappedIfSafe
        )
        guard !windowsModuleData.isEmpty, !sharedLibraryData.isEmpty else {
            throw FileSystemItemPolicyError.notRegularNonSymlinkFile(
                windowsModuleData.isEmpty ? sourceWindowsModule : sourceSharedLibrary
            )
        }

        var identityInput = Data("forgeplay-d3dmetal-ngx-bridge-v1\n".utf8)
        identityInput.append(contentsOf: SHA256.hash(data: windowsModuleData))
        identityInput.append(contentsOf: SHA256.hash(data: sharedLibraryData))
        let identity = SHA256.hash(data: identityInput)
            .map { String(format: "%02x", $0) }
            .joined()
        let bridgeRoot = prefix
            .appending(path: ".forgeplay", directoryHint: .isDirectory)
            .appending(path: "renderer-bridges", directoryHint: .isDirectory)
            .appending(path: "d3dmetal", directoryHint: .isDirectory)
            .appending(path: identity, directoryHint: .isDirectory)
        let windowsModule = bridgeRoot.appending(path: windowsModuleRelativePath)
        let sharedLibrary = bridgeRoot.appending(path: sharedLibraryRelativePath)
        let unixModule = bridgeRoot.appending(path: unixModuleRelativePath)

        for directory in [
            bridgeRoot,
            windowsModule.deletingLastPathComponent(),
            sharedLibrary.deletingLastPathComponent(),
            unixModule.deletingLastPathComponent()
        ] {
            let privateComponentCount =
                directory.standardizedFileURL.pathComponents.count -
                prefix.standardizedFileURL.pathComponents.count
            try FileSystemItemPolicy.prepareOwnedDirectoryTree(
                directory,
                trustedAncestor: prefix,
                privateTailComponentCount: privateComponentCount
            )
        }

        try materialize(
            windowsModuleData,
            at: windowsModule,
            fileManager: fileManager
        )
        try materialize(
            sharedLibraryData,
            at: sharedLibrary,
            fileManager: fileManager
        )
        try materializeSharedUnixModuleLink(
            at: unixModule,
            sharedLibrary: sharedLibrary,
            fileManager: fileManager
        )
        guard isUsable(at: bridgeRoot, fileManager: fileManager) else {
            throw FileSystemItemPolicyError.unsafeManagedDirectory(
                bridgeRoot,
                "MetalFX/NGX 브리지 파생 파일 검증에 실패했습니다."
            )
        }
        return bridgeRoot
    }

    nonisolated static func isUsable(
        at bridgeRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let windowsModule = bridgeRoot.appending(path: windowsModuleRelativePath)
        let sharedLibrary = bridgeRoot.appending(path: sharedLibraryRelativePath)
        let unixModule = bridgeRoot.appending(path: unixModuleRelativePath)
        guard FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
            from: bridgeRoot,
            to: windowsModule,
            fileManager: fileManager
        ),
        FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
            from: bridgeRoot,
            to: sharedLibrary,
            fileManager: fileManager
        ),
        FileSystemItemPolicy.isRegularNonSymlinkFile(
            windowsModule,
            fileManager: fileManager
        ),
        FileSystemItemPolicy.isRegularNonSymlinkFile(
            sharedLibrary,
            fileManager: fileManager
        ),
        let values = try? unixModule.resourceValues(forKeys: [.isSymbolicLinkKey]),
        values.isSymbolicLink == true,
        let destination = try? fileManager.destinationOfSymbolicLink(
            atPath: unixModule.path
        ),
        destination == sharedUnixModuleLinkTarget,
        unixModule.resolvingSymlinksInPath().standardizedFileURL ==
            sharedLibrary.standardizedFileURL else {
            return false
        }
        return true
    }

    private nonisolated static func materialize(
        _ data: Data,
        at destination: URL,
        fileManager: FileManager
    ) throws {
        if FileSystemItemPolicy.isRegularNonSymlinkFile(
            destination,
            fileManager: fileManager
        ),
        let existing = try? Data(contentsOf: destination, options: .mappedIfSafe),
        existing == data {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
            return
        }
        try removeItemIfPresent(destination, fileManager: fileManager)
        try data.write(to: destination, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
        try FileSystemItemPolicy.requireRegularNonSymlinkFile(
            destination,
            fileManager: fileManager
        )
        guard try Data(
            contentsOf: destination,
            options: .mappedIfSafe
        ) == data else {
            throw FileSystemItemPolicyError.unsafeManagedDirectory(
                destination,
                "파생 파일의 내용이 검증된 원본과 일치하지 않습니다."
            )
        }
    }

    private nonisolated static func materializeSharedUnixModuleLink(
        at unixModule: URL,
        sharedLibrary: URL,
        fileManager: FileManager
    ) throws {
        if let values = try? unixModule.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true,
           let destination = try? fileManager.destinationOfSymbolicLink(
               atPath: unixModule.path
           ),
           destination == sharedUnixModuleLinkTarget,
           unixModule.resolvingSymlinksInPath().standardizedFileURL ==
                sharedLibrary.standardizedFileURL {
            return
        }
        try removeItemIfPresent(unixModule, fileManager: fileManager)
        try fileManager.createSymbolicLink(
            atPath: unixModule.path,
            withDestinationPath: sharedUnixModuleLinkTarget
        )
    }

    private nonisolated static func removeItemIfPresent(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        )
        let isSymbolicLink =
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
                .isSymbolicLink) == true
        if exists || isSymbolicLink {
            try fileManager.removeItem(at: url)
        }
    }
}

struct WindowsRuntimeValidation: Hashable {
    var isValid: Bool
    var executableURL: URL?
    var message: String
}

struct AppleSupplementalRendererImportResult: Hashable {
    var executableURL: URL
    var installedSupplementalRedistURL: URL?
    var message: String
}

enum WindowsRendererRuntimeGateStatus: Hashable, Sendable {
    case verified(evidence: String)
    case failed(evidence: String, technicalDetail: String)
    case unverified(technicalDetail: String)

    var admitsLaunch: Bool {
        if case .verified = self { return true }
        return false
    }

    var diagnosticSummary: String {
        switch self {
        case .verified(let evidence):
            "verified: \(evidence)"
        case .failed(let evidence, let technicalDetail):
            "failed: \(evidence); \(technicalDetail)"
        case .unverified(let technicalDetail):
            "unverified: \(technicalDetail)"
        }
    }
}

struct SteamRendererPolicyAvailability: Hashable, Sendable {
    let isAvailable: Bool
    let userMessageLocalizationKey: String?
    let technicalDetail: String?

    static let available = Self(
        isAvailable: true,
        userMessageLocalizationKey: nil,
        technicalDetail: nil
    )

    static func unavailable(
        userMessageLocalizationKey: String? = nil,
        technicalDetail: String? = nil
    ) -> Self {
        Self(
            isAvailable: false,
            userMessageLocalizationKey: userMessageLocalizationKey,
            technicalDetail: technicalDetail
        )
    }
}

struct WindowsRuntimeCapability: Hashable, Sendable {
    enum GraphicsBackend: Hashable, Sendable {
        case d3dMetal
        case moltenVKOrVulkan
        case unsupportedByMetadata
        case unknown

        var diagnosticName: String {
            switch self {
            case .d3dMetal: "d3dMetal"
            case .moltenVKOrVulkan: "moltenVKOrVulkan"
            case .unsupportedByMetadata: "unsupportedByMetadata"
            case .unknown: "unknown"
            }
        }
    }

    enum Direct3DGeneration: String, Hashable, CaseIterable, Sendable {
        case d3d9
        case d3d11
        case d3d12
    }

    var executableURL: URL
    var graphicsBackend: GraphicsBackend
    var availableGraphicsBackends: Set<GraphicsBackend>
    var evidence: [String]
    var limitations: [String]
    var supportedDirect3DGenerations: Set<Direct3DGeneration>
    var supportedDirect3DGenerationsByBackend: [GraphicsBackend: Set<Direct3DGeneration>]
    var rendererRuntimeGates:
        [SteamRendererPolicyPreference: WindowsRendererRuntimeGateStatus]

    init(
        executableURL: URL,
        graphicsBackend: GraphicsBackend,
        evidence: [String],
        limitations: [String],
        availableGraphicsBackends: Set<GraphicsBackend>? = nil,
        supportedDirect3DGenerations: Set<Direct3DGeneration>? = nil,
        supportedDirect3DGenerationsByBackend: [GraphicsBackend: Set<Direct3DGeneration>]? = nil,
        rendererRuntimeGates:
            [SteamRendererPolicyPreference: WindowsRendererRuntimeGateStatus] = [:]
    ) {
        self.executableURL = executableURL
        let resolvedGraphicsBackends = availableGraphicsBackends ?? {
            switch graphicsBackend {
            case .d3dMetal, .moltenVKOrVulkan:
                [graphicsBackend]
            case .unsupportedByMetadata, .unknown:
                []
            }
        }()
        let resolvedDirect3DGenerations = supportedDirect3DGenerations ?? {
            switch graphicsBackend {
            case .d3dMetal, .moltenVKOrVulkan:
                [.d3d11]
            case .unsupportedByMetadata, .unknown:
                []
            }
        }()
        let resolvedDirect3DSupport = supportedDirect3DGenerationsByBackend ?? Dictionary(
            uniqueKeysWithValues: resolvedGraphicsBackends.map {
                ($0, resolvedDirect3DGenerations)
            }
        )

        self.graphicsBackend = graphicsBackend
        self.availableGraphicsBackends = resolvedGraphicsBackends
        self.evidence = evidence
        self.limitations = limitations
        self.supportedDirect3DGenerationsByBackend = resolvedDirect3DSupport
        self.supportedDirect3DGenerations = Set(
            resolvedDirect3DSupport.values.flatMap { $0 }
        )
        self.rendererRuntimeGates = rendererRuntimeGates
    }

    var supportsModernDirect3DGames: Bool {
        !supportedDirect3DGenerations.isEmpty
    }

    var supportsDirect3D11Games: Bool {
        supportedDirect3DGenerations.contains(.d3d11)
    }

    var supportsDirect3D9Games: Bool {
        supportedDirect3DGenerations.contains(.d3d9)
    }

    var supportsDirect3D12Games: Bool {
        supportedDirect3DGenerations.contains(.d3d12)
    }

    var supportsD3DMetalBackend: Bool {
        availableGraphicsBackends.contains(.d3dMetal) &&
            !(supportedDirect3DGenerationsByBackend[.d3dMetal] ?? []).isEmpty
    }

    var supportsVulkanBackend: Bool {
        availableGraphicsBackends.contains(.moltenVKOrVulkan) &&
            !(supportedDirect3DGenerationsByBackend[.moltenVKOrVulkan] ?? []).isEmpty
    }

    func supportedDirect3DGenerations(
        for backend: GraphicsBackend
    ) -> Set<Direct3DGeneration> {
        supportedDirect3DGenerationsByBackend[backend] ?? []
    }

    func rendererRuntimeGate(
        for preference: SteamRendererPolicyPreference
    ) -> WindowsRendererRuntimeGateStatus? {
        rendererRuntimeGates[preference]
    }

    var direct3DGenerationsByBackendDiagnostics: [String: [String]] {
        Dictionary(uniqueKeysWithValues: supportedDirect3DGenerationsByBackend
            .filter { availableGraphicsBackends.contains($0.key) && !$0.value.isEmpty }
            .map { backend, generations in
                (
                    backend.diagnosticName,
                    Direct3DGeneration.allCases
                        .filter(generations.contains)
                        .map(\.rawValue)
                )
            })
    }

    var direct3DGenerationsByBackendSummary: String {
        direct3DGenerationsByBackendDiagnostics.keys.sorted().map { backend in
            "\(backend)=[\(direct3DGenerationsByBackendDiagnostics[backend, default: []].joined(separator: ","))]"
        }.joined(separator: "; ")
    }

    var direct3DGenerationSummary: String {
        Direct3DGeneration.allCases
            .filter(supportedDirect3DGenerations.contains)
            .map(\.rawValue)
            .joined(separator: ",")
    }

    var supportsSteamClientNetworking: Bool {
        SteamClientCompatibilityVerifier.verify(capability: self).supportsNetworking
    }

    var supportsWindowsSteamClientLaunches: Bool {
        SteamClientCompatibilityVerifier.verify(capability: self).canLaunchWindowsSteam
    }

    var supportsManagedSteamGameLaunches: Bool {
        SteamClientCompatibilityVerifier.verify(capability: self).canLaunchManagedSteamGames
    }

    var hasFailedSteamUIRenderingValidation: Bool {
        limitations.contains("steam-cef-webhelper-renderer-validation-failed")
    }

    var hasKnownBadSteamUIConformance: Bool {
        limitations.contains("steam-ui-failed-known-bad")
    }

    var isUnsupportedExternalApplicationRunner: Bool {
        ExternalApplicationRunnerPolicy.isUnsupportedRunnerExecutable(executableURL)
    }

    var hasAppleD3DMetalRenderer: Bool {
        evidence.contains { $0.hasSuffix("D3DMetal.framework/D3DMetal") }
    }

    var hasDXMTRenderer: Bool {
        evidence.contains { $0.hasSuffix("renderer/dxmt/wine/x86_64-unix/winemetal.so") }
    }

    var steamUIRenderingValidationWarningMessage: String? {
        guard hasFailedSteamUIRenderingValidation || hasKnownBadSteamUIConformance else { return nil }
        if hasKnownBadSteamUIConformance {
            return "앱에 포함된 ForgePlay Runtime은 Windows Steam UI conformance 결과가 failed_known_bad로 기록되어 있습니다. 같은 ForgePlay Runtime·Steam 프리픽스 실행에서 로그인/Steam Guard/Library UI를 다시 검증하기 전에는 성공으로 판정하지 않습니다."
        }
        return "이 ForgePlay Runtime은 이전 Windows Steam CEF/WebHelper UI 렌더링 검증 실패 기록이 있습니다. Steam 실행으로 재검증할 수 있지만, Windows Steam 로그인/라이브러리 UI가 실제로 보이기 전에는 release-capable로 보지 않습니다."
    }

    var userMessage: String {
        if let steamClientBlockerMessage = SteamClientCompatibilityVerifier.steamClientBlockerMessage(for: self),
           SteamClientCompatibilityVerifier.hasExplicitSteamUIBlocker(in: self) {
            return steamClientBlockerMessage
        }
        if limitations.contains("incomplete-vulkan-direct3d-renderer") {
            return "앱에 포함된 ForgePlay Runtime은 Vulkan 런타임 일부는 있지만 DXVK/D3D9/D3D11/DXGI 구성이 불완전해 게임 렌더러 payload로 사용할 수 없습니다."
        }
        if limitations.contains("incomplete-d3dmetal-runtime") {
            return "앱에 포함된 ForgePlay Runtime은 D3DMetal 일부 파일만 포함되어 있습니다. 실제 게임 실행에는 D3DMetal.framework, 공유/셰이더 라이브러리, d3d11/d3d12/dxgi Wine 모듈이 같은 renderer payload에 완전하게 포함되거나 완전한 DXMT 대안이 필요합니다."
        }
        if limitations.contains("missing-dxmt-macdrv-metal-window-bridge") {
            return "앱에 포함된 ForgePlay Runtime에는 Metal renderer 파일은 있지만 Wine HWND를 macOS Metal view로 연결하는 창 표면 계약이 없습니다. D3D11/12 장치 생성 뒤 실제 게임 swapchain 생성에서 종료될 수 있으므로 최신 ForgePlay 빌드로 업데이트하거나 앱을 다시 설치하세요."
        }
        if let steamClientBlockerMessage = SteamClientCompatibilityVerifier.steamClientBlockerMessage(for: self) {
            return steamClientBlockerMessage
        }
        if limitations.contains("incomplete-vulkan-runtime") {
            return "앱에 포함된 ForgePlay Runtime은 Vulkan/MoltenVK 구성요소가 일부만 포함되어 있습니다. 최신 ForgePlay 빌드로 업데이트하거나 앱을 다시 설치하세요."
        }
        if limitations.contains("missing-direct3d-renderer") {
            return "앱에 포함된 ForgePlay Runtime은 Windows용 Steam 실행에 필요한 런타임은 있지만 Direct3D 화면 출력을 Metal/Vulkan으로 변환하는 D3DMetal/DXVK 렌더러가 포함되어 있지 않습니다. Steam에서 실행한 Direct3D 게임이 검은 화면으로 실행될 수 있습니다."
        }

        switch graphicsBackend {
        case .d3dMetal:
            if hasAppleD3DMetalRenderer && hasDXMTRenderer {
                return "D3DMetal/DXMT 기반 게임 렌더러 payload를 확인했습니다."
            }
            if hasDXMTRenderer {
                return "DXMT/Metal 기반 게임 렌더러 payload를 확인했습니다."
            }
            return "D3DMetal 기반 게임 렌더러 payload를 확인했습니다."
        case .moltenVKOrVulkan:
            return "Vulkan/DXVK 기반 게임 렌더러 payload를 확인했습니다."
        case .unsupportedByMetadata:
            return "앱에 포함된 ForgePlay Runtime은 Vulkan/D3DMetal 없이 빌드되어 현대 Direct3D 게임에 사용할 수 없습니다."
        case .unknown:
            return "앱에 포함된 ForgePlay Runtime에서 Windows용 Steam과 Steam에서 실행할 Direct3D 게임에 필요한 D3DMetal/Vulkan 렌더러 payload를 확인하지 못했습니다."
        }
    }

    var technicalSummary: String {
        let evidenceSummary = evidence.isEmpty ? "evidence: none" : "evidence: \(evidence.joined(separator: "; "))"
        let limitationSummary = limitations.isEmpty ? "limitations: none" : "limitations: \(limitations.joined(separator: "; "))"
        let generationSummary = direct3DGenerationSummary.isEmpty
            ? "Direct3D generations: none"
            : "Direct3D generations: \(direct3DGenerationSummary)"
        let backendSummary = availableGraphicsBackends.isEmpty
            ? "available graphics backends: none"
            : "available graphics backends: \(availableGraphicsBackends.map(\.diagnosticName).sorted().joined(separator: ","))"
        let backendGenerationSummary = direct3DGenerationsByBackendDiagnostics.isEmpty
            ? "Direct3D generations by backend: none"
            : "Direct3D generations by backend: \(direct3DGenerationsByBackendSummary)"
        let runtimeGateSummary = rendererRuntimeGates.isEmpty
            ? "renderer runtime gates: none"
            : "renderer runtime gates: " + rendererRuntimeGates.keys
                .sorted { $0.rawValue < $1.rawValue }
                .map {
                    "\($0.rawValue)=[\(rendererRuntimeGates[$0]?.diagnosticSummary ?? "missing")]"
                }
                .joined(separator: "; ")
        return "\(evidenceSummary). \(limitationSummary). \(generationSummary). \(backendSummary). \(backendGenerationSummary). \(runtimeGateSummary). executable: \(executableURL.path)"
    }
}

private struct WindowsRendererRuntimeGateSBOM: Decodable {
    struct Payload: Decodable {
        let path: String
        let contentSHA256: String
    }

    let hostSupportPayload: [Payload]
}

enum WindowsRuntimeDisplayName {
    static func productRuntimeName(for capability: WindowsRuntimeCapability) -> String {
        switch capability.graphicsBackend {
        case .d3dMetal:
            if capability.hasAppleD3DMetalRenderer && capability.hasDXMTRenderer {
                "ForgePlay Runtime · D3DMetal/DXMT"
            } else if capability.hasDXMTRenderer {
                "ForgePlay Runtime · DXMT/Metal"
            } else {
                "ForgePlay Runtime · D3DMetal"
            }
        case .moltenVKOrVulkan:
            "ForgePlay Runtime · Vulkan/DXVK"
        case .unsupportedByMetadata, .unknown:
            "ForgePlay Runtime"
        }
    }

    static func displayName(for executable: URL, capability: WindowsRuntimeCapability? = nil) -> String {
        if ExternalApplicationRunnerPolicy.isUnsupportedRunnerExecutable(executable) {
            return "Unsupported External Application Runtime"
        }
        if ForgePlayBundledWindowsRuntimePolicy.isBundledRuntimeExecutable(executable) {
            return "ForgePlay Runtime"
        }

        let lowercasedPath = executable.standardizedFileURL.path.lowercased()
        if lowercasedPath.contains("/forgeplayruntime/") ||
            lowercasedPath.contains("/runners/forgeplayruntime/") {
            return "ForgePlay Runtime"
        }
        let launcherName = executable.lastPathComponent.lowercased()
        if launcherName == "wine" || launcherName == "wine64" {
            return switch capability?.graphicsBackend {
            case .d3dMetal:
                "D3DMetal Runtime"
            case .moltenVKOrVulkan:
                "Vulkan/DXVK Runtime"
            case .unsupportedByMetadata, .unknown, .none:
                "Windows Runtime"
            }
        }

        return executable.lastPathComponent
    }

    static func statusSummary(for capability: WindowsRuntimeCapability) -> String {
        if capability.isUnsupportedExternalApplicationRunner {
            return "다른 macOS 앱의 런타임 감지됨 · ForgePlay 실행 엔진으로 사용할 수 없음"
        }
        if capability.supportsWindowsSteamClientLaunches,
           capability.hasFailedSteamUIRenderingValidation {
            return "Steam UI 렌더링 실패 기록 있음 · 재검증 필요"
        }
        if capability.hasKnownBadSteamUIConformance {
            return "Steam UI failed_known_bad · 실행 차단"
        }
        if capability.supportsWindowsSteamClientLaunches && capability.supportsModernDirect3DGames {
            return "Windows Steam 사용 가능 · 게임 렌더러 확인됨"
        }
        if capability.supportsWindowsSteamClientLaunches {
            return "Windows Steam 사용 가능"
        }
        return capability.userMessage
    }
}

extension SteamRendererPolicyPreference {
    static let dxvkRuntimeUnavailableLocalizationKey =
        "DXVK 파일은 포함되어 있지만 현재 번들 조합이 실제 DXGI 장치 검증을 통과하지 못했습니다. 호환되는 검증된 DXVK 런타임이 제공되기 전까지 DXVK를 사용할 수 없습니다."

    func isSatisfied(by capability: WindowsRuntimeCapability) -> Bool {
        availability(in: capability).isAvailable
    }

    func availability(
        in capability: WindowsRuntimeCapability
    ) -> SteamRendererPolicyAvailability {
        switch self {
        case .d3dMetal:
            return capability.supportsD3DMetalBackend &&
                capability.hasCompleteRendererEvidence(
                    rootMarkers: [
                        "renderer/d3dmetal/",
                        "managed-supplemental-d3dmetal-"
                    ],
                    requiredSuffixes: [
                        "/external/D3DMetal.framework/D3DMetal",
                        "/external/libd3dshared.dylib",
                        "/wine/x86_64-windows/d3d11.dll",
                        "/wine/x86_64-windows/d3d12.dll",
                        "/wine/x86_64-windows/dxgi.dll"
                    ]
                )
                ? .available
                : .unavailable()
        case .dxmt:
            return capability.supportsD3DMetalBackend &&
                !capability.limitations.contains("missing-dxmt-macdrv-metal-window-bridge") &&
                capability.hasCompleteRendererEvidence(
                    rootMarkers: ["renderer/dxmt/"],
                    requiredSuffixes: [
                        "/wine/x86_64-unix/winemetal.so",
                        "/wine/x86_64-windows/d3d11.dll",
                        "/wine/x86_64-windows/dxgi.dll",
                        "/wine/x86_64-windows/winemetal.dll",
                        "/wine/i386-windows/d3d11.dll",
                        "/wine/i386-windows/dxgi.dll",
                        "/wine/i386-windows/winemetal.dll"
                    ]
                )
                ? .available
                : .unavailable()
        case .d9vk:
            return capability.supportsVulkanBackend &&
                capability.hasCompleteRendererEvidence(
                    rootMarkers: ["renderer/d9vk/"],
                    requiredSuffixes: [
                        "/wine/x86_64-windows/d3d9.dll",
                        "/wine/i386-windows/d3d9.dll"
                    ]
                )
                ? .available
                : .unavailable()
        case .vulkan:
            let hasPayload = capability.hasCompleteRendererEvidence(
                rootMarkers: ["renderer/dxvk/"],
                requiredSuffixes: [
                    "/wine/x86_64-windows/d3d9.dll",
                    "/wine/x86_64-windows/d3d11.dll",
                    "/wine/x86_64-windows/dxgi.dll",
                    "/wine/i386-windows/d3d9.dll",
                    "/wine/i386-windows/d3d11.dll",
                    "/wine/i386-windows/dxgi.dll"
                ]
            )
            guard hasPayload else { return .unavailable() }
            let gate = capability.rendererRuntimeGate(for: .vulkan) ??
                .unverified(
                    technicalDetail:
                        "no DXVK device gate was captured for this Runtime capability generation"
                )
            guard gate.admitsLaunch else {
                return .unavailable(
                    userMessageLocalizationKey:
                        Self.dxvkRuntimeUnavailableLocalizationKey,
                    technicalDetail: gate.diagnosticSummary
                )
            }
            return capability.supportsVulkanBackend
                ? .available
                : .unavailable()
        }
    }
}

private extension WindowsRuntimeCapability {
    func hasCompleteRendererEvidence(
        rootMarkers: [String],
        requiredSuffixes: [String]
    ) -> Bool {
        let rendererEvidence = evidence.filter { path in
            rootMarkers.contains { path.contains($0) }
        }
        return requiredSuffixes.allSatisfy { suffix in
            rendererEvidence.contains { $0.hasSuffix(suffix) }
        }
    }
}

extension SteamRendererPolicySelection {
    func resolvedLaunchPreference(
        capability: WindowsRuntimeCapability,
        recipePreference: SteamRendererPolicyPreference? = nil
    ) -> SteamRendererPolicyPreference? {
        guard let forcedPreference else { return nil }
        return forcedPreference.isSatisfied(by: capability) ? forcedPreference : nil
    }
}

enum AppleSupplementalRendererLayout {
    static let supplementalRedistDirectoryName = "SupplementalEvaluationEnvironment"
    static let redistLibraryRelativePath = "redist/lib"
    static let redistExternalFrameworkRelativePath = "external/D3DMetal.framework"
    static let redistWineRelativePath = "wine"
    static let maxNestedDMGDepth = 2
    static let maxRedistSearchDepth = 5
}

enum ForgePlaySupplementalRendererPolicy {
    private static let legacyStorageRelativePath = "Apps/Runners/AppleGPTK"

    static func storageRoot(forManagedRoot managedRoot: URL) -> URL {
        managedRoot
            .appending(
                path: ForgePlayPathRole.appleSupplementalRenderer.rawValue,
                directoryHint: .isDirectory
            )
    }

    static func rendererRoot(forManagedRoot managedRoot: URL) -> URL {
        storageRoot(forManagedRoot: managedRoot)
            .appending(path: AppleSupplementalRendererLayout.supplementalRedistDirectoryName, directoryHint: .isDirectory)
            .appending(path: "lib", directoryHint: .isDirectory)
    }

    static func legacyRendererRoot(forManagedRoot managedRoot: URL) -> URL {
        managedRoot
            .appending(path: legacyStorageRelativePath, directoryHint: .isDirectory)
            .appending(path: AppleSupplementalRendererLayout.supplementalRedistDirectoryName, directoryHint: .isDirectory)
            .appending(path: "lib", directoryHint: .isDirectory)
    }

    static func rendererRoot(containingPrefix prefix: URL) -> URL? {
        let standardizedPrefix = prefix.standardizedFileURL
        let components = standardizedPrefix.pathComponents
        guard let prefixesIndex = components.lastIndex(of: "Prefixes"), prefixesIndex > 0 else {
            return nil
        }

        let managedRoot = URL(
            fileURLWithPath: NSString.path(withComponents: Array(components[..<prefixesIndex])),
            isDirectory: true
        ).standardizedFileURL
        let prefixesRoot = managedRoot
            .appending(path: ForgePlayPathRole.prefixes.rawValue, directoryHint: .isDirectory)
            .standardizedFileURL
        guard standardizedPrefix.path == prefixesRoot.path ||
            standardizedPrefix.path.hasPrefix("\(prefixesRoot.path)/") else {
            return nil
        }
        return rendererRoot(forManagedRoot: managedRoot)
    }
}

/// Metadata-only identity for the package objects that can change the result
/// of a Windows Runtime capability inspection. Runtime payload authentication
/// remains owned by `RuntimeManifestResolver`; this generation only prevents a
/// cached capability projection from crossing a package or supplemental
/// renderer replacement.
struct WindowsRuntimeCapabilityGeneration: Hashable, Sendable {
    private struct ObjectIdentity: Hashable, Sendable {
        let path: String
        let isPresent: Bool
        let device: UInt64
        let inode: UInt64
        let mode: UInt16
        let linkCount: UInt64
        let byteCount: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        static func capture(_ url: URL) throws -> Self {
            let normalized = url.standardizedFileURL
            var status = stat()
            guard lstat(normalized.path, &status) == 0 else {
                if errno == ENOENT || errno == ENOTDIR {
                    return Self(
                        path: normalized.path,
                        isPresent: false,
                        device: 0,
                        inode: 0,
                        mode: 0,
                        linkCount: 0,
                        byteCount: 0,
                        modificationSeconds: 0,
                        modificationNanoseconds: 0,
                        changeSeconds: 0,
                        changeNanoseconds: 0
                    )
                }
                throw WindowsRuntimeCapabilityProviderError
                    .generationUnavailable(
                        normalized,
                        String(cString: strerror(errno))
                    )
            }
            return Self(
                path: normalized.path,
                isPresent: true,
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino),
                mode: UInt16(status.st_mode),
                linkCount: UInt64(status.st_nlink),
                byteCount: Int64(status.st_size),
                modificationSeconds: Int64(status.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
                changeSeconds: Int64(status.st_ctimespec.tv_sec),
                changeNanoseconds: Int64(status.st_ctimespec.tv_nsec)
            )
        }
    }

    private let objects: [ObjectIdentity]

    static func capture(
        executable: URL,
        supplementalRendererRoot: URL?
    ) throws -> Self {
        let candidates = WindowsRuntimeService
            .runtimeCapabilityGenerationCandidateURLs(
                for: executable,
                supplementalRendererRoot: supplementalRendererRoot,
                fileManager: .default
            )
        var identityCandidates = candidates
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath()
                .standardizedFileURL
            if resolved.path != candidate.standardizedFileURL.path {
                identityCandidates.append(resolved)
            }
        }
        let uniqueCandidates = Dictionary(
            identityCandidates.map {
                ($0.standardizedFileURL.path, $0.standardizedFileURL)
            },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.path < $1.path }
        return Self(objects: try uniqueCandidates.map(ObjectIdentity.capture))
    }
}

struct WindowsRuntimeCapabilitySnapshot: Hashable, Sendable {
    let capability: WindowsRuntimeCapability
    let generation: WindowsRuntimeCapabilityGeneration
    let executable: URL
    let supplementalRendererRoot: URL?
}

enum WindowsRuntimeCapabilityProviderError: LocalizedError, Sendable {
    case generationUnavailable(URL, String)
    case generationChanged(URL)

    var errorDescription: String? {
        switch self {
        case .generationUnavailable(let url, let reason):
            "ForgePlay Runtime 기능 세대를 확인하지 못했습니다: \(url.path). \(reason)"
        case .generationChanged(let url):
            "ForgePlay Runtime 파일이 기능 확인 중 변경되었습니다. 변경이 끝난 뒤 다시 시도하세요: \(url.path)"
        }
    }
}

/// The single owner of expensive Runtime capability inspection. The actor
/// coalesces concurrent callers, but the scan itself runs in a detached task so
/// neither MainActor nor this actor is monopolized while binaries are mapped.
actor WindowsRuntimeCapabilityProvider {
    typealias GenerationProvider = @Sendable (
        _ executable: URL,
        _ supplementalRendererRoot: URL?
    ) throws -> WindowsRuntimeCapabilityGeneration
    typealias Inspector = @Sendable (
        _ executable: URL,
        _ supplementalRendererRoot: URL?
    ) throws -> WindowsRuntimeCapability

    private struct RequestKey: Hashable, Sendable {
        let executablePath: String
        let supplementalRendererRootPath: String?
    }

    private struct InFlight: Sendable {
        let id: UUID
        let generation: WindowsRuntimeCapabilityGeneration
        let task: Task<WindowsRuntimeCapabilitySnapshot, Error>
    }

    static let shared = WindowsRuntimeCapabilityProvider()

    private let generationProvider: GenerationProvider
    private let inspector: Inspector
    private var cachedByRequest: [RequestKey: WindowsRuntimeCapabilitySnapshot] = [:]
    private var inFlightByRequest: [RequestKey: InFlight] = [:]

    init(
        generationProvider: @escaping GenerationProvider = {
            try WindowsRuntimeCapabilityGeneration.capture(
                executable: $0,
                supplementalRendererRoot: $1
            )
        },
        inspector: @escaping Inspector = {
            WindowsRuntimeService.inspectRuntimeCapability(
                for: $0,
                supplementalRendererRoot: $1,
                fileManager: .default
            )
        }
    ) {
        self.generationProvider = generationProvider
        self.inspector = inspector
    }

    func snapshot(
        for executable: URL,
        supplementalRendererRoot: URL? = nil
    ) async throws -> WindowsRuntimeCapabilitySnapshot {
        let normalizedExecutable = executable.standardizedFileURL
        let normalizedSupplementalRoot = supplementalRendererRoot?
            .standardizedFileURL
        let key = RequestKey(
            executablePath: normalizedExecutable.path,
            supplementalRendererRootPath: normalizedSupplementalRoot?.path
        )

        for _ in 0..<3 {
            let currentGeneration = try generationProvider(
                normalizedExecutable,
                normalizedSupplementalRoot
            )
            if let cached = cachedByRequest[key],
               cached.generation == currentGeneration {
                return cached
            }
            cachedByRequest.removeValue(forKey: key)

            let inFlight: InFlight
            if let existing = inFlightByRequest[key],
               existing.generation == currentGeneration {
                inFlight = existing
            } else {
                let id = UUID()
                let generationProvider = generationProvider
                let inspector = inspector
                let expectedGeneration = currentGeneration
                let task = Task.detached(priority: .userInitiated) {
                    for _ in 0..<2 {
                        let before = try generationProvider(
                            normalizedExecutable,
                            normalizedSupplementalRoot
                        )
                        guard before == expectedGeneration else {
                            throw WindowsRuntimeCapabilityProviderError
                                .generationChanged(normalizedExecutable)
                        }
                        let capability = try inspector(
                            normalizedExecutable,
                            normalizedSupplementalRoot
                        )
                        let after = try generationProvider(
                            normalizedExecutable,
                            normalizedSupplementalRoot
                        )
                        if after == expectedGeneration {
                            return WindowsRuntimeCapabilitySnapshot(
                                capability: capability,
                                generation: after,
                                executable: normalizedExecutable,
                                supplementalRendererRoot:
                                    normalizedSupplementalRoot
                            )
                        }
                    }
                    throw WindowsRuntimeCapabilityProviderError
                        .generationChanged(normalizedExecutable)
                }
                inFlight = InFlight(
                    id: id,
                    generation: currentGeneration,
                    task: task
                )
                inFlightByRequest[key] = inFlight
            }

            do {
                let inspected = try await inFlight.task.value
                if inFlightByRequest[key]?.id == inFlight.id {
                    inFlightByRequest.removeValue(forKey: key)
                }
                let readbackGeneration = try generationProvider(
                    normalizedExecutable,
                    normalizedSupplementalRoot
                )
                guard inspected.generation == readbackGeneration else {
                    continue
                }
                cachedByRequest[key] = inspected
                return inspected
            } catch {
                if inFlightByRequest[key]?.id == inFlight.id {
                    inFlightByRequest.removeValue(forKey: key)
                }
                if let providerError = error as?
                    WindowsRuntimeCapabilityProviderError,
                   case .generationChanged = providerError {
                    continue
                }
                throw error
            }
        }
        throw WindowsRuntimeCapabilityProviderError
            .generationChanged(normalizedExecutable)
    }

    /// A final transaction-bound check. A mismatch never returns the stale
    /// value: it performs one coalesced off-main reinspection and either returns
    /// the new stable generation or fails closed.
    func revalidated(
        _ snapshot: WindowsRuntimeCapabilitySnapshot
    ) async throws -> WindowsRuntimeCapabilitySnapshot {
        let currentGeneration = try generationProvider(
            snapshot.executable,
            snapshot.supplementalRendererRoot
        )
        guard currentGeneration != snapshot.generation else {
            return snapshot
        }
        return try await self.snapshot(
            for: snapshot.executable,
            supplementalRendererRoot: snapshot.supplementalRendererRoot
        )
    }

    func invalidate(
        executable: URL,
        supplementalRendererRoot: URL? = nil
    ) {
        let key = RequestKey(
            executablePath: executable.standardizedFileURL.path,
            supplementalRendererRootPath:
                supplementalRendererRoot?.standardizedFileURL.path
        )
        cachedByRequest.removeValue(forKey: key)
        inFlightByRequest[key]?.task.cancel()
        inFlightByRequest.removeValue(forKey: key)
    }
}

@MainActor
final class WindowsRuntimeService {
    static let appleSupplementalRendererDownloadURL = ExternalLinkPolicy.appleGamePortingToolkitDownloadURL
    private nonisolated static let unsupportedSteamCEFChildWindowMarkers = [
        "Cross-process child window Metal swapchains are not implemented",
        "DC for window %p of other process: not implemented"
    ]

    private let pathManager: PathManager
    private let runner: SafeProcessRunner
    private let fileManager: FileManager
    private let bundledRuntimeExecutableProvider: () -> URL?
    private let lifecycleCoordinator: SteamPrefixLifecycleCoordinator
    private let runtimeCapabilityProvider: WindowsRuntimeCapabilityProvider
    private let supplementalRendererAuthenticator:
        any AppleSupplementalRendererAuthenticating

    init(
        pathManager: PathManager,
        runner: SafeProcessRunner,
        fileManager: FileManager = .default,
        bundledRuntimeExecutableProvider: @escaping () -> URL? = {
            ForgePlayBundledWindowsRuntimePolicy.bundledRuntimeExecutableURL()
        },
        lifecycleCoordinator: SteamPrefixLifecycleCoordinator? = nil,
        runtimeCapabilityProvider: WindowsRuntimeCapabilityProvider = .shared,
        supplementalRendererAuthenticator:
            any AppleSupplementalRendererAuthenticating =
                AppleSupplementalRendererTrustPolicy()
    ) {
        self.pathManager = pathManager
        self.runner = runner
        self.fileManager = fileManager
        self.bundledRuntimeExecutableProvider = bundledRuntimeExecutableProvider
        self.lifecycleCoordinator = lifecycleCoordinator ?? SteamPrefixLifecycleCoordinator()
        self.runtimeCapabilityProvider = runtimeCapabilityProvider
        self.supplementalRendererAuthenticator =
            supplementalRendererAuthenticator
    }

    func validateExecutable(_ url: URL) -> WindowsRuntimeValidation {
        do {
            return try validateExecutableStrict(url)
        } catch {
            return WindowsRuntimeValidation(
                isValid: false,
                executableURL: nil,
                message: forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    func validateExecutableStrict(_ url: URL) throws -> WindowsRuntimeValidation {
        guard fileManager.fileExists(atPath: url.path) else {
            return WindowsRuntimeValidation(isValid: false, executableURL: nil, message: "파일이 존재하지 않습니다.")
        }
        guard let bundledRunner = bundledRuntimeExecutableProvider()?.standardizedFileURL,
              url.standardizedFileURL.path == bundledRunner.path else {
            return WindowsRuntimeValidation(
                isValid: false,
                executableURL: nil,
                message: "ForgePlay는 앱에 포함된 ForgePlay Runtime만 실행 엔진으로 사용합니다."
            )
        }
        if let validationMessage = Self.runtimeExecutableValidationMessage(
            url,
            requireExecutable: true,
            fileManager: fileManager
        ) {
            return WindowsRuntimeValidation(isValid: false, executableURL: nil, message: validationMessage)
        }
        if let integrityMessage = Self.wineRuntimeIntegrityMessage(for: url, fileManager: fileManager) {
            return WindowsRuntimeValidation(isValid: false, executableURL: nil, message: integrityMessage)
        }
        return WindowsRuntimeValidation(isValid: true, executableURL: url, message: url.path)
    }

    func importAppleSupplementalRenderer(
        at selectedURL: URL
    ) async throws -> AppleSupplementalRendererImportResult {
        let token = try lifecycleCoordinator.begin(.supplementalRendererImport)
        defer { lifecycleCoordinator.end(token) }

        let managedRoot = try pathManager.validateCurrentManagedRoot()
        let managedRootLeases: [ManagedRootOperationLease]
        do {
            managedRootLeases = try ManagedRootOperationLease.acquireExclusive(
                forManagedRoots: [managedRoot],
                fileManager: fileManager
            )
        } catch ManagedRootOperationLeaseError.operationInProgress {
            throw SteamPrefixLifecycleError.operationInProgress
        }
        defer { managedRootLeases.reversed().forEach { $0.release() } }

        return try await importAppleSupplementalRendererWithExclusiveAccess(at: selectedURL)
    }

    private func importAppleSupplementalRendererWithExclusiveAccess(
        at selectedURL: URL
    ) async throws -> AppleSupplementalRendererImportResult {
        let didStartSecurityScope = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }

        let bundledRunner = try requiredBundledRuntimeExecutable(actionName: "importAppleSupplementalRenderer")
        let supplementalStorageRoot = try supplementalRendererStorageRoot()
        let supplementalRendererAuthenticator =
            self.supplementalRendererAuthenticator
        let result: AppleSupplementalRendererImportResult
        if selectedURL.pathExtension.lowercased() == "dmg" {
            result = try await Task.detached(priority: .userInitiated) {
                try Self.mountAndImportSupplementalRenderer(
                    from: selectedURL,
                    supplementalStorageRoot: supplementalStorageRoot,
                    bundledRuntimeExecutable: bundledRunner,
                    supplementalRendererAuthenticator:
                        supplementalRendererAuthenticator,
                    fileManager: .default
                )
            }.value
        } else {
            guard try Self.containsEvaluationRedistStrict(in: selectedURL, fileManager: fileManager) else {
                throw WindowsRuntimeServiceError.invalidSelection(
                    "Apple 공식 Evaluation environment DMG 또는 redist 폴더를 선택하세요. 외부 실행 파일이나 다른 앱의 런타임은 가져오지 않습니다."
                )
            }
            result = try await Task.detached(priority: .userInitiated) {
                try Self.installSupplementalRenderer(
                    from: selectedURL,
                    supplementalStorageRoot: supplementalStorageRoot,
                    bundledRuntimeExecutable: bundledRunner,
                    supplementalRendererAuthenticator:
                        supplementalRendererAuthenticator,
                    fileManager: .default
                )
            }.value
        }

        try Self.validateWineRuntimeIntegrity(for: result.executableURL, fileManager: fileManager)
        _ = try await probeAndValidate(executable: result.executableURL)
        return result
    }

    private func requiredBundledRuntimeExecutable(actionName: String) throws -> URL {
        guard let executable = bundledRuntimeExecutableProvider() else {
            throw ForgePlayRuntimeCapabilityError.bundledRuntimeUnavailable(actionName: actionName)
        }
        if let validationMessage = Self.runtimeExecutableValidationMessage(
            executable,
            requireExecutable: true,
            fileManager: fileManager
        ) {
            throw WindowsRuntimeServiceError.invalidSelection(validationMessage)
        }
        try Self.validateWineRuntimeIntegrity(for: executable, fileManager: fileManager)
        return executable.standardizedFileURL
    }

    private func validateBundledRuntimeSelection(_ executable: URL, actionName: String) throws {
        let bundledRunner = try requiredBundledRuntimeExecutable(actionName: actionName)
        guard executable.standardizedFileURL.path == bundledRunner.path else {
            throw ForgePlayRuntimeCapabilityError.nonBundledRuntimeRejected(
                actionName: actionName,
                path: executable.path
            )
        }
    }

    func probe(executable: URL) async throws -> ProcessRunResult {
        try validateBundledRuntimeSelection(executable, actionName: "probeRuntime")
        if let validationMessage = Self.runtimeExecutableValidationMessage(
            executable,
            requireExecutable: true,
            fileManager: fileManager
        ) {
            throw WindowsRuntimeServiceError.invalidSelection(validationMessage)
        }
        try Self.validateWineRuntimeIntegrity(for: executable, fileManager: fileManager)
        let logDirectory = try pathManager.url(for: .installLogs)
        return try await runner.run(.probeRuntime(executable: executable, logDirectory: logDirectory))
    }

    func probeAndValidate(
        executable: URL,
        requiresModernGraphicsBackend: Bool = false
    ) async throws -> ProcessRunResult {
        try validateBundledRuntimeSelection(executable, actionName: "probeRuntime")
        let result = try await probe(executable: executable)
        guard Self.probeLooksUsable(result) else {
            throw WindowsRuntimeServiceError.probeFailed(result)
        }
        if requiresModernGraphicsBackend {
            _ = try validateModernGameLaunchSupport(executable: executable)
        }
        return result
    }

    func inspectRuntimeCapability(executable: URL) throws -> WindowsRuntimeCapability {
        if let validationMessage = Self.runtimeExecutableValidationMessage(
            executable,
            requireExecutable: true,
            fileManager: fileManager
        ) {
            throw WindowsRuntimeServiceError.invalidSelection(validationMessage)
        }
        try Self.validateWineRuntimeIntegrity(for: executable, fileManager: fileManager)
        let supplementalRendererRoot = try installedSupplementalRendererRoot()
        return Self.inspectRuntimeCapability(
            for: executable,
            supplementalRendererRoot: supplementalRendererRoot,
            fileManager: fileManager
        )
    }

    /// Production transaction entry point. Package validation and managed-root
    /// selection remain MainActor-owned, while all generation capture and
    /// binary capability inspection run through the non-MainActor provider.
    func runtimeCapabilitySnapshot(
        executable: URL
    ) async throws -> WindowsRuntimeCapabilitySnapshot {
        if let validationMessage = Self.runtimeExecutableValidationMessage(
            executable,
            requireExecutable: true,
            fileManager: fileManager
        ) {
            throw WindowsRuntimeServiceError.invalidSelection(validationMessage)
        }
        try Self.validateWineRuntimeIntegrity(
            for: executable,
            fileManager: fileManager
        )
        let supplementalRendererRoot = try installedSupplementalRendererRoot()
        return try await runtimeCapabilityProvider.snapshot(
            for: executable,
            supplementalRendererRoot: supplementalRendererRoot
        )
    }

    /// Rechecks the current managed supplemental-root selection as well as the
    /// snapshot generation. A root switch obtains a new stable snapshot; an
    /// in-place generation change is reinspected by the provider off MainActor.
    func revalidatedRuntimeCapabilitySnapshot(
        _ snapshot: WindowsRuntimeCapabilitySnapshot,
        executable: URL
    ) async throws -> WindowsRuntimeCapabilitySnapshot {
        let normalizedExecutable = executable.standardizedFileURL
        if let validationMessage = Self.runtimeExecutableValidationMessage(
            normalizedExecutable,
            requireExecutable: true,
            fileManager: fileManager
        ) {
            throw WindowsRuntimeServiceError.invalidSelection(validationMessage)
        }
        try Self.validateWineRuntimeIntegrity(
            for: normalizedExecutable,
            fileManager: fileManager
        )
        guard snapshot.executable.standardizedFileURL == normalizedExecutable else {
            return try await runtimeCapabilitySnapshot(
                executable: normalizedExecutable
            )
        }
        let currentSupplementalRoot = try installedSupplementalRendererRoot()?
            .standardizedFileURL
        guard currentSupplementalRoot == snapshot.supplementalRendererRoot?
            .standardizedFileURL else {
            return try await runtimeCapabilityProvider.snapshot(
                for: normalizedExecutable,
                supplementalRendererRoot: currentSupplementalRoot
            )
        }
        return try await runtimeCapabilityProvider.revalidated(snapshot)
    }

    /// Explicit invalidation is used after ForgePlay replaces a managed
    /// supplemental renderer. Generation readback already covers out-of-band
    /// changes, while this cancels any older in-flight request immediately.
    func invalidateRuntimeCapabilitySnapshot(
        executable: URL
    ) async throws {
        let supplementalRendererRoot = try installedSupplementalRendererRoot()
        await runtimeCapabilityProvider.invalidate(
            executable: executable,
            supplementalRendererRoot: supplementalRendererRoot
        )
    }

    func validateModernGameLaunchSupport(executable: URL) throws -> WindowsRuntimeCapability {
        let capability = try inspectRuntimeCapability(executable: executable)
        let verification = SteamClientCompatibilityVerifier.verify(capability: capability)
        guard verification.canLaunchManagedSteamGames else {
            throw WindowsRuntimeServiceError.missingSteamRendererCapability(capability)
        }
        return capability
    }

    func validateWindowsSteamClientLaunchSupport(executable: URL) throws -> WindowsRuntimeCapability {
        let capability = try inspectRuntimeCapability(executable: executable)
        let verification = SteamClientCompatibilityVerifier.verify(capability: capability)
        guard verification.canLaunchWindowsSteam else {
            throw WindowsRuntimeServiceError.missingSteamRendererCapability(capability)
        }
        return capability
    }

    private nonisolated static func mountAndImportSupplementalRenderer(
        from dmgURL: URL,
        supplementalStorageRoot: URL,
        bundledRuntimeExecutable: URL,
        supplementalRendererAuthenticator:
            any AppleSupplementalRendererAuthenticating,
        fileManager: FileManager
    ) throws -> AppleSupplementalRendererImportResult {
        var mountedVolumes: [URL] = []
        defer {
            for volume in mountedVolumes.reversed() {
                detachMountedVolume(volume)
            }
        }

        let mountURLs = try mountDiskImage(dmgURL, mountedVolumes: &mountedVolumes)
        for mountURL in mountURLs {
            if let result = try supplementalRendererImportResult(
                at: mountURL,
                supplementalStorageRoot: supplementalStorageRoot,
                bundledRuntimeExecutable: bundledRuntimeExecutable,
                supplementalRendererAuthenticator:
                    supplementalRendererAuthenticator,
                fileManager: fileManager,
                mountedVolumes: &mountedVolumes,
                nestedDepth: 0
            ) {
                return result
            }
        }
        throw WindowsRuntimeServiceError.invalidSelection(
            "DMG 안에서 Apple Evaluation environment redist를 찾지 못했습니다."
        )
    }

    private nonisolated static func mountDiskImage(
        _ dmgURL: URL,
        mountedVolumes: inout [URL]
    ) throws -> [URL] {
        if !FileSystemItemPolicy.isRegularNonSymlinkFile(dmgURL, fileManager: .default) {
            try requireDiskImageFile(dmgURL, fileManager: .default)
        }
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        let capture = try BoundedProcessExecutor.capture(
            executable: hdiutil,
            arguments: ["attach", "-readonly", "-nobrowse", "-plist", dmgURL.path],
            timeout: 120
        )

        guard capture.didExit, !capture.didTimeOut, capture.exitCode == 0 else {
            let errorText = decodedProcessErrorText(
                capture.stderr,
                processName: "hdiutil"
            )
            throw WindowsRuntimeServiceError.invalidSelection("DMG를 열 수 없습니다(\(dmgURL.lastPathComponent)). \(errorText)")
        }

        let data = capture.stdout
        let mountURLs = try mountedVolumeURLs(fromHdiutilAttachPlist: data, diskImageName: dmgURL.lastPathComponent)
        mountedVolumes.append(contentsOf: mountURLs)
        return mountURLs
    }

    nonisolated static func decodedProcessErrorText(_ data: Data, processName: String) -> String {
        guard !data.isEmpty else {
            return "\(processName) stderr was empty."
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return "\(processName) stderr was not valid UTF-8 (\(data.count) bytes)."
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "\(processName) stderr was empty."
        }
        return trimmed
    }

    nonisolated static func mountedVolumeURLs(
        fromHdiutilAttachPlist data: Data,
        diskImageName: String
    ) throws -> [URL] {
        var plistFormat = PropertyListSerialization.PropertyListFormat.xml
        let plistObject: Any
        do {
            plistObject = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &plistFormat
            )
        } catch {
            throw WindowsRuntimeServiceError.invalidSelection(
                "DMG를 마운트했지만 마운트 정보를 읽지 못했습니다(\(diskImageName)). \(forgePlayTechnicalErrorSummary(error))"
            )
        }
        guard let plist = plistObject as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw WindowsRuntimeServiceError.invalidSelection(
                "DMG를 마운트했지만 마운트 정보 형식이 올바르지 않습니다(\(diskImageName))."
            )
        }

        let mountURLs = entities.compactMap { entity -> URL? in
            guard let mountPoint = entity["mount-point"] as? String,
                  !mountPoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: mountPoint)
        }
        guard !mountURLs.isEmpty else {
            throw WindowsRuntimeServiceError.invalidSelection(
                "DMG를 마운트했지만 마운트 지점을 찾지 못했습니다(\(diskImageName))."
            )
        }
        return mountURLs
    }

    private nonisolated static func supplementalRendererImportResult(
        at mountURL: URL,
        supplementalStorageRoot: URL,
        bundledRuntimeExecutable: URL,
        supplementalRendererAuthenticator:
            any AppleSupplementalRendererAuthenticating,
        fileManager: FileManager,
        mountedVolumes: inout [URL],
        nestedDepth: Int
    ) throws -> AppleSupplementalRendererImportResult? {
        if try containsEvaluationRedistStrict(in: mountURL, fileManager: fileManager) {
            return try installSupplementalRenderer(
                from: mountURL,
                supplementalStorageRoot: supplementalStorageRoot,
                bundledRuntimeExecutable: bundledRuntimeExecutable,
                supplementalRendererAuthenticator:
                    supplementalRendererAuthenticator,
                fileManager: fileManager
            )
        }

        guard nestedDepth < AppleSupplementalRendererLayout.maxNestedDMGDepth else {
            return nil
        }

        for nestedDMG in try nestedDiskImages(in: mountURL, fileManager: fileManager) {
            let nestedMountURLs = try mountDiskImage(nestedDMG, mountedVolumes: &mountedVolumes)
            for nestedMountURL in nestedMountURLs {
                if let result = try supplementalRendererImportResult(
                    at: nestedMountURL,
                    supplementalStorageRoot: supplementalStorageRoot,
                    bundledRuntimeExecutable: bundledRuntimeExecutable,
                    supplementalRendererAuthenticator:
                        supplementalRendererAuthenticator,
                    fileManager: fileManager,
                    mountedVolumes: &mountedVolumes,
                    nestedDepth: nestedDepth + 1
                ) {
                    return result
                }
            }
        }
        return nil
    }

    private nonisolated static func nestedDiskImages(in root: URL, fileManager: FileManager) throws -> [URL] {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw WindowsRuntimeServiceError.sourceScanFailed(root, CocoaError(.fileReadUnknown))
        }

        var images: [URL] = []
        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - root.pathComponents.count
            if depth > 4 {
                enumerator.skipDescendants()
                continue
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            } catch {
                throw WindowsRuntimeServiceError.sourceScanFailed(root, error)
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isDirectory != true else { continue }
            guard values.isRegularFile == true,
                  url.pathExtension.lowercased() == "dmg" else { continue }
            images.append(url)
        }
        if let enumerationError {
            throw WindowsRuntimeServiceError.sourceScanFailed(root, enumerationError)
        }
        return images.sorted {
            let lhsEvaluation = $0.lastPathComponent.localizedCaseInsensitiveContains("Evaluation environment")
            let rhsEvaluation = $1.lastPathComponent.localizedCaseInsensitiveContains("Evaluation environment")
            if lhsEvaluation != rhsEvaluation {
                return lhsEvaluation
            }
            return $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private nonisolated static func detachMountedVolume(_ url: URL) {
        if runHdiutilDetach(arguments: ["detach", "-quiet", url.path]) {
            return
        }
        Thread.sleep(forTimeInterval: 0.1)
        if runHdiutilDetach(arguments: ["detach", "-quiet", url.path]) {
            return
        }
        _ = runHdiutilDetach(arguments: ["detach", "-force", "-quiet", url.path])
    }

    private nonisolated static func runHdiutilDetach(arguments: [String]) -> Bool {
        do {
            let capture = try BoundedProcessExecutor.capture(
                executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: arguments,
                timeout: 20
            )
            return capture.didExit && !capture.didTimeOut && capture.exitCode == 0
        } catch {
            return false
        }
    }

    private func supplementalRendererStorageRoot() throws -> URL {
        let root = try pathManager.url(for: .appleSupplementalRenderer)
        try pathManager.createDirectoryIfNeeded(root)
        return root
    }

    private func installedSupplementalRendererRoot() throws -> URL? {
        let managedRoot = try pathManager.validateCurrentManagedRoot()
        let candidateRoots = [
            ForgePlaySupplementalRendererPolicy.rendererRoot(forManagedRoot: managedRoot),
            ForgePlaySupplementalRendererPolicy.legacyRendererRoot(forManagedRoot: managedRoot)
        ]
        for rendererRoot in candidateRoots where fileManager.fileExists(atPath: rendererRoot.path) {
            do {
                try FileSystemItemPolicy.requireNonSymlinkDirectory(rendererRoot, fileManager: fileManager)
                try supplementalRendererAuthenticator.authenticate(
                    rendererRoot: rendererRoot,
                    fileManager: fileManager
                )
            } catch {
                throw WindowsRuntimeServiceError.supplementalRedistScanFailed(rendererRoot, error)
            }
            return rendererRoot
        }
        return nil
    }

    private nonisolated static func replaceDirectory<Result>(
        at destination: URL,
        withContentsOf source: URL,
        fileManager: FileManager,
        validateInstalled: (URL) throws -> Result
    ) throws -> Result {
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appending(
            path: ".\(destination.lastPathComponent).staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let backup = parent.appending(
            path: ".\(destination.lastPathComponent).backup-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        var didMoveExistingToBackup = false
        var shouldRemoveBackup = true
        defer {
            try? fileManager.removeItem(at: staging)
            if shouldRemoveBackup {
                try? fileManager.removeItem(at: backup)
            }
        }

        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let contents = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for item in contents {
            try fileManager.copyItem(at: item, to: staging.appending(path: item.lastPathComponent))
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: backup)
            didMoveExistingToBackup = true
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if didMoveExistingToBackup,
               !fileManager.fileExists(atPath: destination.path),
               fileManager.fileExists(atPath: backup.path) {
                do {
                    try fileManager.moveItem(at: backup, to: destination)
                } catch let rollbackError {
                    shouldRemoveBackup = false
                    throw WindowsRuntimeServiceError.payloadReplacementRollbackFailed(
                        destination: destination,
                        backup: backup,
                        originalError: error,
                        rollbackError: rollbackError
                    )
                }
            }
            throw error
        }
        do {
            return try validateInstalled(destination)
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                do {
                    try fileManager.removeItem(at: destination)
                } catch let cleanupError {
                    shouldRemoveBackup = false
                    throw WindowsRuntimeServiceError.payloadReplacementRollbackFailed(
                        destination: destination,
                        backup: backup,
                        originalError: error,
                        rollbackError: cleanupError
                    )
                }
            }
            if didMoveExistingToBackup,
               !fileManager.fileExists(atPath: destination.path),
               fileManager.fileExists(atPath: backup.path) {
                do {
                    try fileManager.moveItem(at: backup, to: destination)
                } catch let rollbackError {
                    shouldRemoveBackup = false
                    throw WindowsRuntimeServiceError.payloadReplacementRollbackFailed(
                        destination: destination,
                        backup: backup,
                        originalError: error,
                        rollbackError: rollbackError
                    )
                }
            }
            throw error
        }
    }

    private nonisolated static func installSupplementalRenderer(
        from source: URL,
        supplementalStorageRoot: URL,
        bundledRuntimeExecutable: URL,
        supplementalRendererAuthenticator:
            any AppleSupplementalRendererAuthenticating,
        fileManager: FileManager
    ) throws -> AppleSupplementalRendererImportResult {
        let installedRedist = try installSupplementalRedist(
            from: source,
            supplementalStorageRoot: supplementalStorageRoot,
            supplementalRendererAuthenticator:
                supplementalRendererAuthenticator,
            fileManager: fileManager
        )
        try validateWineRuntimeIntegrity(for: bundledRuntimeExecutable, fileManager: fileManager)
        return AppleSupplementalRendererImportResult(
            executableURL: bundledRuntimeExecutable,
            installedSupplementalRedistURL: installedRedist,
            message: "Apple D3DMetal 보조 렌더러를 앱 데이터 영역에 설치했습니다. 실행 엔진은 앱에 포함된 ForgePlay Runtime으로 유지됩니다."
        )
    }

    private nonisolated static func installSupplementalRedist(
        from source: URL,
        supplementalStorageRoot: URL,
        supplementalRendererAuthenticator:
            any AppleSupplementalRendererAuthenticating,
        fileManager: FileManager
    ) throws -> URL {
        guard let redistLib = try evaluationRedistLibraryStrict(in: source, fileManager: fileManager) else {
            throw WindowsRuntimeServiceError.invalidSelection("Evaluation environment 안에서 redist/lib 폴더를 찾지 못했습니다.")
        }
        try validateSupplementalRedistLinks(in: redistLib, fileManager: fileManager)
        try supplementalRendererAuthenticator.authenticate(
            rendererRoot: redistLib,
            fileManager: fileManager
        )
        let destination = supplementalRedistDirectory(for: supplementalStorageRoot)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let installedRedist = try replaceDirectory(
            at: destination,
            withContentsOf: redistLib,
            fileManager: fileManager
        ) { installed in
            try FileSystemItemPolicy.requireNonSymlinkDirectory(installed, fileManager: fileManager)
            try validateSupplementalRedistLinks(
                in: installed,
                fileManager: fileManager
            )
            try supplementalRendererAuthenticator.authenticate(
                rendererRoot: installed,
                fileManager: fileManager
            )
            return installed
        }
        return installedRedist
    }

    private nonisolated static func supplementalRedistDirectory(for supplementalStorageRoot: URL) -> URL {
        supplementalStorageRoot
            .appending(path: AppleSupplementalRendererLayout.supplementalRedistDirectoryName, directoryHint: .isDirectory)
            .appending(path: "lib", directoryHint: .isDirectory)
    }

    private nonisolated static func wineBinDirectory(for executable: URL) -> URL? {
        let binDirectory = executable.deletingLastPathComponent()
        guard binDirectory.lastPathComponent == "bin" else { return nil }
        return binDirectory
    }

    private nonisolated static func bundleContentsDirectory(
        for executable: URL,
        fileManager: FileManager
    ) -> URL? {
        let components = executable.standardizedFileURL.pathComponents
        guard let contentsIndex = components.lastIndex(of: "Contents") else { return nil }
        let contents = URL(fileURLWithPath: NSString.path(withComponents: Array(components[0...contentsIndex])))
        guard FileSystemItemPolicy.isNonSymlinkDirectory(contents, fileManager: fileManager) else {
            return nil
        }
        return contents
    }

    private nonisolated static let capabilityMetadataRelativePaths = [
        "RuntimeManifest.json",
        "RuntimeSBOM.json",
        "BUILD-METADATA.md",
        "STEAM-UI-CONFORMANCE.json",
        "steam-ui-conformance.json",
        "SteamUIConformance.json"
    ]

    /// Exact authenticated package objects covered by the failed actual-device
    /// DXVK gate. A different Runtime generation does not inherit this failure;
    /// it remains unverified until that generation carries successful device
    /// evidence. The Runtime manifest authenticates RuntimeSBOM.json before the
    /// production capability snapshot is admitted.
    private nonisolated static let failedDXVKRuntimeGatePayloadSHA256ByPath = [
        "Frameworks/renderer/dxvk/version":
            "517036ffbc4858eba27a01b85badcfd5e5c2a59a3d35d1898ab34567f818e799",
        "Frameworks/renderer/dxvk/wine/i386-windows/d3d11.dll":
            "72a892033bdd8f11c103527776da637e02c9f9e6e7b501a37c8fbbb6349ac676",
        "Frameworks/renderer/dxvk/wine/i386-windows/dxgi.dll":
            "06a8a821ef3ac35d4a83a1c2b74d3fecc6d9a9ebdac1fe3a08531f2c11214658",
        "Frameworks/renderer/dxvk/wine/x86_64-windows/d3d11.dll":
            "4ff4916573be5bfa433286d61594d1cc6901953694681c5e61f3d1263c025b97",
        "Frameworks/renderer/dxvk/wine/x86_64-windows/dxgi.dll":
            "c13bcc082c0cb1d08bcb0b722483e4c78dbf595224ad7c90399281421b04f6f4",
        "wine/lib/libMoltenVK.dylib":
            "bfc34848e4ebc11888084ae4a5394ada95c37766c23b3ed8c22d79ec3c1f4f3c"
    ]

    private nonisolated static let capabilityD3DMetalRendererLayouts = [
        "lib64/apple_gptk",
        "Frameworks/renderer/d3dmetal",
        "Contents/Frameworks/renderer/d3dmetal"
    ]

    private nonisolated static let capabilityD3DMetalEvidenceRelativePaths = [
        "external/D3DMetal.framework/D3DMetal",
        "external/D3DMetal.framework/Resources/Info.plist",
        "external/D3DMetal.framework/Resources/default.metallib",
        "external/D3DMetal.framework/Resources/libdxccontainer.dylib",
        "external/D3DMetal.framework/Resources/libdxcompiler.dylib",
        "external/D3DMetal.framework/Resources/libdxilconv.dylib",
        "external/D3DMetal.framework/Resources/libmetalirconverter.dylib",
        "external/libd3dshared.dylib",
        "wine/x86_64-unix/d3d9.so",
        "wine/x86_64-unix/d3d10.so",
        "wine/x86_64-unix/d3d11.so",
        "wine/x86_64-unix/d3d12.so",
        "wine/x86_64-unix/dxgi.so",
        "wine/x86_64-unix/nvapi.so",
        "wine/x86_64-unix/nvapi64.so",
        "wine/x86_64-unix/nvngx-on-metalfx.so",
        "wine/x86_64-windows/d3d9.dll",
        "wine/x86_64-windows/d3d10.dll",
        "wine/x86_64-windows/d3d11.dll",
        "wine/x86_64-windows/d3d12.dll",
        "wine/x86_64-windows/dxgi.dll",
        "wine/x86_64-windows/nvapi.dll",
        "wine/x86_64-windows/nvapi64.dll",
        "wine/x86_64-windows/nvngx-on-metalfx.dll"
    ]

    private nonisolated static let capabilityDXMTRelativePaths = [
        "Frameworks/renderer/dxmt/external/D3DMetal.framework/D3DMetal",
        "Frameworks/renderer/dxmt/external/libd3dshared.dylib",
        "Frameworks/renderer/dxmt/wine/x86_64-unix/d3d9.so",
        "Frameworks/renderer/dxmt/wine/x86_64-unix/d3d11.so",
        "Frameworks/renderer/dxmt/wine/x86_64-unix/dxgi.so",
        "Frameworks/renderer/dxmt/wine/x86_64-unix/winemetal.so",
        "Frameworks/renderer/dxmt/wine/i386-windows/d3d11.dll",
        "Frameworks/renderer/dxmt/wine/i386-windows/dxgi.dll",
        "Frameworks/renderer/dxmt/wine/i386-windows/winemetal.dll",
        "Frameworks/renderer/dxmt/wine/x86_64-windows/d3d9.dll",
        "Frameworks/renderer/dxmt/wine/x86_64-windows/d3d11.dll",
        "Frameworks/renderer/dxmt/wine/x86_64-windows/dxgi.dll",
        "Frameworks/renderer/dxmt/wine/x86_64-windows/winemetal.dll",
        "Contents/Frameworks/renderer/dxmt/external/D3DMetal.framework/D3DMetal",
        "Contents/Frameworks/renderer/dxmt/external/libd3dshared.dylib",
        "Contents/Frameworks/renderer/dxmt/wine/x86_64-unix/d3d9.so",
        "Contents/Frameworks/renderer/dxmt/wine/x86_64-unix/d3d11.so",
        "Contents/Frameworks/renderer/dxmt/wine/x86_64-unix/dxgi.so",
        "Contents/Frameworks/renderer/dxmt/wine/x86_64-unix/winemetal.so",
        "Contents/Frameworks/renderer/dxmt/wine/i386-windows/d3d11.dll",
        "Contents/Frameworks/renderer/dxmt/wine/i386-windows/dxgi.dll",
        "Contents/Frameworks/renderer/dxmt/wine/i386-windows/winemetal.dll",
        "Contents/Frameworks/renderer/dxmt/wine/x86_64-windows/d3d9.dll",
        "Contents/Frameworks/renderer/dxmt/wine/x86_64-windows/d3d11.dll",
        "Contents/Frameworks/renderer/dxmt/wine/x86_64-windows/dxgi.dll",
        "Contents/Frameworks/renderer/dxmt/wine/x86_64-windows/winemetal.dll"
    ]

    private nonisolated static let capabilityVulkanRendererRelativePaths = [
        "lib/dxvk/x86_64-windows/d3d9.dll",
        "lib/dxvk/x86_64-windows/d3d11.dll",
        "lib/dxvk/x86_64-windows/dxgi.dll",
        "lib/dxvk/i386-windows/d3d9.dll",
        "lib/dxvk/i386-windows/d3d11.dll",
        "lib/dxvk/i386-windows/dxgi.dll",
        "Frameworks/renderer/dxvk/wine/x86_64-windows/d3d9.dll",
        "Frameworks/renderer/dxvk/wine/x86_64-windows/d3d11.dll",
        "Frameworks/renderer/dxvk/wine/x86_64-windows/dxgi.dll",
        "Frameworks/renderer/dxvk/wine/i386-windows/d3d9.dll",
        "Frameworks/renderer/dxvk/wine/i386-windows/d3d11.dll",
        "Frameworks/renderer/dxvk/wine/i386-windows/dxgi.dll",
        "Frameworks/renderer/d9vk/wine/x86_64-windows/d3d9.dll",
        "Frameworks/renderer/d9vk/wine/i386-windows/d3d9.dll",
        "Contents/Frameworks/renderer/dxvk/wine/x86_64-windows/d3d9.dll",
        "Contents/Frameworks/renderer/dxvk/wine/x86_64-windows/d3d11.dll",
        "Contents/Frameworks/renderer/dxvk/wine/x86_64-windows/dxgi.dll",
        "Contents/Frameworks/renderer/dxvk/wine/i386-windows/d3d9.dll",
        "Contents/Frameworks/renderer/dxvk/wine/i386-windows/d3d11.dll",
        "Contents/Frameworks/renderer/dxvk/wine/i386-windows/dxgi.dll",
        "Contents/Frameworks/renderer/d9vk/wine/x86_64-windows/d3d9.dll",
        "Contents/Frameworks/renderer/d9vk/wine/i386-windows/d3d9.dll"
    ]

    private nonisolated static let capabilityVulkanLoaderRelativePaths = [
        "lib/libvulkan.dylib",
        "lib/libvulkan.1.dylib",
        "Contents/Frameworks/libvulkan.dylib",
        "Contents/Frameworks/libvulkan.1.dylib",
        "Contents/SharedSupport/wine/lib/libvulkan.dylib",
        "Contents/SharedSupport/wine/lib/libvulkan.1.dylib"
    ]

    private nonisolated static let capabilityMoltenVKRelativePaths = [
        "lib64/libMoltenVK.dylib",
        "Frameworks/libMoltenVK.dylib",
        "lib/libMoltenVK.dylib",
        "lib/vulkan/libMoltenVK.dylib",
        "Contents/Frameworks/libMoltenVK.dylib",
        "Contents/SharedSupport/wine/lib/libMoltenVK.dylib"
    ]

    private nonisolated static let capabilityVulkanICDRelativePaths = [
        "etc/vulkan/icd.d/MoltenVK_icd.json",
        "share/vulkan/icd.d/MoltenVK_icd.json",
        "lib/vulkan/icd.d/MoltenVK_icd.json",
        "vulkan/icd.d/MoltenVK_icd.json",
        "Contents/Frameworks/vulkan/icd.d/MoltenVK_icd.json",
        "Contents/SharedSupport/wine/etc/vulkan/icd.d/MoltenVK_icd.json",
        "Contents/SharedSupport/wine/share/vulkan/icd.d/MoltenVK_icd.json"
    ]

    private nonisolated static let steamWebHelperRootScopedArgumentPolicyKernelbaseRelativePaths = [
        "lib/wine/i386-windows/kernelbase.dll",
        "lib/wine/x86_64-windows/kernelbase.dll"
    ]

    private nonisolated static let steamWebHelperRootScopedArgumentPolicyMarkers = [
        SteamWebHelperLaunchPolicy.argumentTargetEnvironmentKey,
        SteamWebHelperLaunchPolicy.argumentAppendEnvironmentKey,
        SteamWebHelperLaunchPolicy.argumentRootOnlyEnvironmentKey
    ]

    private nonisolated static let capabilityWineRootRelativePaths =
        steamWebHelperRootScopedArgumentPolicyKernelbaseRelativePaths + [
            "lib64/libgnutls.30.dylib",
            "lib64/libgnutls.dylib",
            "lib/libgnutls.30.dylib",
            "lib/libgnutls.dylib",
            "lib/libfreetype.6.dylib",
            "lib/libfreetype.dylib",
            "lib/libvulkan.dylib",
            "lib/libvulkan.1.dylib",
            "lib/libMoltenVK.dylib",
            "lib/vulkan/libMoltenVK.dylib",
            "etc/vulkan/icd.d/MoltenVK_icd.json",
            "share/vulkan/icd.d/MoltenVK_icd.json",
            "lib/vulkan/icd.d/MoltenVK_icd.json",
            "vulkan/icd.d/MoltenVK_icd.json",
            "lib/wine/ntdll.so",
            "lib/wine/x86_64-unix/ntdll.so",
            "lib/wine/i386-unix/ntdll.so",
            "lib/wine/aarch64-unix/ntdll.so",
            "lib/wine/x86_64-unix/winemac.so",
            "lib/external/D3DMetal.framework/D3DMetal",
            "lib/wine/x86_64-unix/d3d10.so",
            "lib/wine/x86_64-unix/d3d11.so",
            "lib/wine/x86_64-unix/d3d12.so",
            "lib/wine/x86_64-unix/dxgi.so",
            "lib/wine/x86_64-unix/nvapi.so",
            "lib/wine/x86_64-unix/nvapi64.so",
            "lib/wine/x86_64-unix/nvngx-on-metalfx.so",
            "lib/wine/x86_64-unix/libd3dshared.dylib",
            "lib/wine/x86_64-windows/d3d10.dll",
            "lib/wine/x86_64-windows/d3d11.dll",
            "lib/wine/x86_64-windows/d3d12.dll",
            "lib/wine/x86_64-windows/dxgi.dll",
            "lib/wine/x86_64-windows/nvapi.dll",
            "lib/wine/x86_64-windows/nvapi64.dll",
            "lib/wine/x86_64-windows/nvngx-on-metalfx.dll"
        ]

    /// Produces the exact metadata/content candidates read by capability
    /// inspection from the same Runtime search roots. Capturing each missing
    /// path as well as each existing one makes nested add/remove and in-place
    /// replacement invalidate the generation without recursively walking the
    /// unrelated Runtime payload.
    nonisolated static func runtimeCapabilityGenerationCandidateURLs(
        for executable: URL,
        supplementalRendererRoot: URL?,
        fileManager: FileManager
    ) -> [URL] {
        let normalizedExecutable = executable.standardizedFileURL
        let roots = runnerCapabilitySearchRoots(
            for: normalizedExecutable,
            fileManager: fileManager
        )
        var candidates = [normalizedExecutable]
        candidates.append(contentsOf: roots)
        let rootRelativePaths = capabilityMetadataRelativePaths +
            capabilityDXMTRelativePaths +
            capabilityVulkanRendererRelativePaths +
            capabilityVulkanLoaderRelativePaths +
            capabilityMoltenVKRelativePaths +
            capabilityVulkanICDRelativePaths +
            capabilityD3DMetalRendererLayouts.flatMap { layout in
                [layout] + capabilityD3DMetalEvidenceRelativePaths.map {
                    "\(layout)/\($0)"
                }
            }
        for root in roots {
            candidates.append(contentsOf: rootRelativePaths.map {
                root.appending(path: $0)
            })
        }
        if let wineRoot = wineRuntimeRoot(
            for: normalizedExecutable,
            fileManager: fileManager
        ) {
            candidates.append(wineRoot)
            candidates.append(contentsOf: capabilityWineRootRelativePaths.map {
                wineRoot.appending(path: $0)
            })
        }
        if let supplementalRendererRoot {
            let root = supplementalRendererRoot.standardizedFileURL
            candidates.append(root)
            candidates.append(root.deletingLastPathComponent())
            candidates.append(contentsOf:
                capabilityD3DMetalEvidenceRelativePaths.map {
                    root.appending(path: $0)
                }
            )
        }
        return deduplicated(candidates)
    }

    nonisolated static func inspectRuntimeCapability(
        for executable: URL,
        supplementalRendererRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> WindowsRuntimeCapability {
        let roots = runnerCapabilitySearchRoots(for: executable, fileManager: fileManager)
        let wineRoot = wineRuntimeRoot(for: executable, fileManager: fileManager)
        let wineRoots = wineRoot.map { [$0] } ?? []
        var evidence: [String] = []
        var limitations: [String] = []
        func appendLimitation(_ limitation: String) {
            guard !limitations.contains(limitation) else { return }
            limitations.append(limitation)
        }
        let isUnsupportedExternalApplicationRunner = ExternalApplicationRunnerPolicy
            .isUnsupportedRunnerExecutable(executable, fileManager: fileManager)
        if isUnsupportedExternalApplicationRunner {
            evidence.append("Unsupported external application runtime")
        }

        let appleD3DMetalInspection = inspectAppleD3DMetalRuntime(
            roots: roots,
            supplementalRendererRoots: [supplementalRendererRoot].compactMap { $0 },
            fileManager: fileManager
        )
        let dxmtEvidence = existingCapabilityEvidence(
            roots: roots,
            relativePaths: [
                "Frameworks/renderer/dxmt/external/D3DMetal.framework/D3DMetal",
                "Frameworks/renderer/dxmt/external/libd3dshared.dylib",
                "Frameworks/renderer/dxmt/wine/x86_64-unix/d3d9.so",
                "Frameworks/renderer/dxmt/wine/x86_64-unix/d3d11.so",
                "Frameworks/renderer/dxmt/wine/x86_64-unix/dxgi.so",
                "Frameworks/renderer/dxmt/wine/x86_64-unix/winemetal.so",
                "Frameworks/renderer/dxmt/wine/i386-windows/d3d11.dll",
                "Frameworks/renderer/dxmt/wine/i386-windows/dxgi.dll",
                "Frameworks/renderer/dxmt/wine/i386-windows/winemetal.dll",
                "Frameworks/renderer/dxmt/wine/x86_64-windows/d3d9.dll",
                "Frameworks/renderer/dxmt/wine/x86_64-windows/d3d11.dll",
                "Frameworks/renderer/dxmt/wine/x86_64-windows/dxgi.dll",
                "Frameworks/renderer/dxmt/wine/x86_64-windows/winemetal.dll",
                "Contents/Frameworks/renderer/dxmt/external/D3DMetal.framework/D3DMetal",
                "Contents/Frameworks/renderer/dxmt/external/libd3dshared.dylib",
                "Contents/Frameworks/renderer/dxmt/wine/x86_64-unix/d3d9.so",
                "Contents/Frameworks/renderer/dxmt/wine/x86_64-unix/d3d11.so",
                "Contents/Frameworks/renderer/dxmt/wine/x86_64-unix/dxgi.so",
                "Contents/Frameworks/renderer/dxmt/wine/x86_64-unix/winemetal.so",
                "Contents/Frameworks/renderer/dxmt/wine/i386-windows/d3d11.dll",
                "Contents/Frameworks/renderer/dxmt/wine/i386-windows/dxgi.dll",
                "Contents/Frameworks/renderer/dxmt/wine/i386-windows/winemetal.dll",
                "Contents/Frameworks/renderer/dxmt/wine/x86_64-windows/d3d9.dll",
                "Contents/Frameworks/renderer/dxmt/wine/x86_64-windows/d3d11.dll",
                "Contents/Frameworks/renderer/dxmt/wine/x86_64-windows/dxgi.dll",
                "Contents/Frameworks/renderer/dxmt/wine/x86_64-windows/winemetal.dll"
            ],
            fileManager: fileManager
        )
        let d3dMetalEvidence = appleD3DMetalInspection.evidence + dxmtEvidence
        evidence.append(contentsOf: d3dMetalEvidence)
        let hasDXMTRendererPayload = dxmtEvidence.contains {
            $0.hasSuffix("renderer/dxmt/wine/x86_64-unix/winemetal.so")
        }
        var hasDXMTMacDriverBridge = !hasDXMTRendererPayload

        let vulkanRendererEvidence = existingCapabilityEvidence(
            roots: roots,
            relativePaths: [
                "lib/dxvk/x86_64-windows/d3d9.dll",
                "lib/dxvk/x86_64-windows/d3d11.dll",
                "lib/dxvk/x86_64-windows/dxgi.dll",
                "lib/dxvk/i386-windows/d3d9.dll",
                "lib/dxvk/i386-windows/d3d11.dll",
                "lib/dxvk/i386-windows/dxgi.dll",
                "Frameworks/renderer/dxvk/wine/x86_64-windows/d3d9.dll",
                "Frameworks/renderer/dxvk/wine/x86_64-windows/d3d11.dll",
                "Frameworks/renderer/dxvk/wine/x86_64-windows/dxgi.dll",
                "Frameworks/renderer/dxvk/wine/i386-windows/d3d9.dll",
                "Frameworks/renderer/dxvk/wine/i386-windows/d3d11.dll",
                "Frameworks/renderer/dxvk/wine/i386-windows/dxgi.dll",
                "Frameworks/renderer/d9vk/wine/x86_64-windows/d3d9.dll",
                "Frameworks/renderer/d9vk/wine/i386-windows/d3d9.dll",
                "Contents/Frameworks/renderer/dxvk/wine/x86_64-windows/d3d9.dll",
                "Contents/Frameworks/renderer/dxvk/wine/x86_64-windows/d3d11.dll",
                "Contents/Frameworks/renderer/dxvk/wine/x86_64-windows/dxgi.dll",
                "Contents/Frameworks/renderer/dxvk/wine/i386-windows/d3d9.dll",
                "Contents/Frameworks/renderer/dxvk/wine/i386-windows/d3d11.dll",
                "Contents/Frameworks/renderer/dxvk/wine/i386-windows/dxgi.dll",
                "Contents/Frameworks/renderer/d9vk/wine/x86_64-windows/d3d9.dll",
                "Contents/Frameworks/renderer/d9vk/wine/i386-windows/d3d9.dll"
            ],
            fileManager: fileManager
        )
        let vulkanLoaderEvidence = existingCapabilityEvidence(
            roots: roots,
            relativePaths: [
                "lib/libvulkan.dylib",
                "lib/libvulkan.1.dylib",
                "Contents/Frameworks/libvulkan.dylib",
                "Contents/Frameworks/libvulkan.1.dylib",
                "Contents/SharedSupport/wine/lib/libvulkan.dylib",
                "Contents/SharedSupport/wine/lib/libvulkan.1.dylib"
            ],
            fileManager: fileManager
        )
        let moltenVKEvidence = existingCapabilityEvidence(
            roots: roots,
            relativePaths: [
                "lib64/libMoltenVK.dylib",
                "Frameworks/libMoltenVK.dylib",
                "lib/libMoltenVK.dylib",
                "lib/vulkan/libMoltenVK.dylib",
                "Contents/Frameworks/libMoltenVK.dylib",
                "Contents/SharedSupport/wine/lib/libMoltenVK.dylib"
            ],
            fileManager: fileManager
        )
        let vulkanICDEvidence = existingCapabilityEvidence(
            roots: roots,
            relativePaths: [
                "etc/vulkan/icd.d/MoltenVK_icd.json",
                "share/vulkan/icd.d/MoltenVK_icd.json",
                "lib/vulkan/icd.d/MoltenVK_icd.json",
                "vulkan/icd.d/MoltenVK_icd.json",
                "Contents/Frameworks/vulkan/icd.d/MoltenVK_icd.json",
                "Contents/SharedSupport/wine/etc/vulkan/icd.d/MoltenVK_icd.json",
                "Contents/SharedSupport/wine/share/vulkan/icd.d/MoltenVK_icd.json"
            ],
            fileManager: fileManager
        )
        let vulkanEvidence = vulkanRendererEvidence + vulkanLoaderEvidence + moltenVKEvidence + vulkanICDEvidence
        evidence.append(contentsOf: vulkanEvidence)

        let wineRootGnuTLSEvidence = existingCapabilityEvidence(
            roots: wineRoots,
            relativePaths: [
                "lib64/libgnutls.30.dylib",
                "lib64/libgnutls.dylib",
                "lib/libgnutls.30.dylib",
                "lib/libgnutls.dylib"
            ],
            fileManager: fileManager
        )
        evidence.append(contentsOf: wineRootGnuTLSEvidence)
        let wineRootFreeTypeEvidence = existingCapabilityEvidence(
            roots: wineRoots,
            relativePaths: [
                "lib/libfreetype.6.dylib",
                "lib/libfreetype.dylib"
            ],
            fileManager: fileManager
        )
        evidence.append(contentsOf: wineRootFreeTypeEvidence)

        let wineRootVulkanLoaderEvidence = existingCapabilityEvidence(
            roots: wineRoots,
            relativePaths: [
                "lib/libvulkan.dylib",
                "lib/libvulkan.1.dylib"
            ],
            fileManager: fileManager
        )
        let wineRootMoltenVKEvidence = existingCapabilityEvidence(
            roots: wineRoots,
            relativePaths: [
                "lib/libMoltenVK.dylib",
                "lib/vulkan/libMoltenVK.dylib"
            ],
            fileManager: fileManager
        )
        let wineRootVulkanICDEvidence = existingCapabilityEvidence(
            roots: wineRoots,
            relativePaths: [
                "etc/vulkan/icd.d/MoltenVK_icd.json",
                "share/vulkan/icd.d/MoltenVK_icd.json",
                "lib/vulkan/icd.d/MoltenVK_icd.json",
                "vulkan/icd.d/MoltenVK_icd.json"
            ],
            fileManager: fileManager
        )
        if let wineRoot {
            if hasSteamWebHelperRootScopedExecutableArgumentPolicy(
                in: wineRoot,
                fileManager: fileManager
            ) {
                evidence.append(
                    "Steam WebHelper root-process-scoped executable argument mechanism in i386/x86_64 kernelbase"
                )
            } else {
                appendLimitation(
                    "missing-steam-webhelper-root-scoped-executable-argument-policy"
                )
            }
            let wineMacDriver = wineRoot.appending(path: "lib/wine/x86_64-unix/winemac.so")
            if safeExistingCapabilityPath(wineMacDriver, fileManager: fileManager) {
                evidence.append("lib/wine/x86_64-unix/winemac.so")
                if binaryFile(wineMacDriver, containsUTF8: "_macdrv_functions") {
                    evidence.append("Metal renderer window-surface contract export")
                    hasDXMTMacDriverBridge = true
                }
                if binaryFileContainsAnyUTF8(
                    wineMacDriver,
                    markers: unsupportedSteamCEFChildWindowMarkers
                ) {
                    appendLimitation("steam-cef-child-window-metal-swapchain-unsupported")
                }
            }
            let activeD3DMetalOverlayEvidence = activeWineD3DMetalOverlayEvidence(
                in: wineRoot,
                fileManager: fileManager
            )
            if !activeD3DMetalOverlayEvidence.isEmpty {
                evidence.append(contentsOf: activeD3DMetalOverlayEvidence)
                appendLimitation("active-d3dmetal-overlay-in-wine-modules")
            }
        }
        if hasDXMTRendererPayload, !hasDXMTMacDriverBridge {
            appendLimitation("missing-dxmt-macdrv-metal-window-bridge")
        }

        let metadataLimitations = runnerMetadataLimitations(roots: roots, fileManager: fileManager)
        limitations.append(contentsOf: metadataLimitations)
        let steamUIConformance = steamUIConformanceEvidence(
            roots: roots,
            fileManager: fileManager
        )
        evidence.append(contentsOf: steamUIConformance.evidence)
        limitations.append(contentsOf: steamUIConformance.limitations)

        let isBuiltWithoutVulkan = metadataLimitations.contains("built-without-vulkan") ||
            metadataLimitations.contains("built-without-vulkan-or-d3dmetal")
        let hasCompleteVulkanRuntime =
            !vulkanLoaderEvidence.isEmpty &&
            !moltenVKEvidence.isEmpty &&
            !vulkanICDEvidence.isEmpty
        let d9vkRendererEvidence = vulkanRendererEvidence.filter {
            $0.contains("renderer/d9vk/")
        }
        let dxvkRendererEvidence = vulkanRendererEvidence.filter {
            $0.contains("renderer/dxvk/") || $0.contains("lib/dxvk/")
        }
        let hasCompleteD9VKRendererPayload =
            hasCompleteVulkanDirect3D9Renderer(evidence: d9vkRendererEvidence)
        let hasCompleteDXVKDirect3D9Payload =
            hasCompleteVulkanDirect3D9Renderer(evidence: dxvkRendererEvidence)
        let hasCompleteDXVKDirect3D11Payload =
            hasCompleteVulkanDirect3D11Renderer(evidence: dxvkRendererEvidence)
        var rendererRuntimeGates:
            [SteamRendererPolicyPreference: WindowsRendererRuntimeGateStatus] = [:]
        if hasCompleteDXVKDirect3D9Payload ||
            hasCompleteDXVKDirect3D11Payload {
            let gate = dxvkRuntimeGate(roots: roots, fileManager: fileManager)
            rendererRuntimeGates[.vulkan] = gate
            evidence.append("DXVK runtime gate: \(gate.diagnosticSummary)")
            if let gateLimitation = gateFailureLimitation(for: gate) {
                appendLimitation(gateLimitation)
            }
        }
        let dxvkRuntimeGateAdmitsLaunch =
            rendererRuntimeGates[.vulkan]?.admitsLaunch == true
        let hasVulkanDirect3D9Renderer =
            hasCompleteVulkanRuntime &&
            (hasCompleteD9VKRendererPayload ||
                (hasCompleteDXVKDirect3D9Payload &&
                    dxvkRuntimeGateAdmitsLaunch))
        let hasVulkanDirect3D11Renderer =
            hasCompleteVulkanRuntime && hasCompleteDXVKDirect3D11Payload &&
            dxvkRuntimeGateAdmitsLaunch
        let hasCompleteDXMTLaunchPayload =
            hasCompleteDXMTRuntime(evidence: dxmtEvidence) && hasDXMTMacDriverBridge
        let hasCompleteD3DMetalPayload =
            appleD3DMetalInspection.supportsCompleteLaunchPayload ||
            hasCompleteDXMTLaunchPayload
        let hasD3DMetalDirect3DRenderer =
            appleD3DMetalInspection.supportsDirect3D11 ||
            appleD3DMetalInspection.supportsDirect3D12 ||
            hasCompleteDXMTLaunchPayload
        let hasVulkanDirect3DRenderer =
            (hasVulkanDirect3D9Renderer || hasVulkanDirect3D11Renderer) &&
            !isBuiltWithoutVulkan
        if !d3dMetalEvidence.isEmpty, !hasCompleteD3DMetalPayload {
            appendLimitation("incomplete-d3dmetal-runtime")
        }
        if !appleD3DMetalInspection.evidence.isEmpty,
           !appleD3DMetalInspection.supportsDirect3D12 {
            appendLimitation("incomplete-d3dmetal-d3d12-runtime")
        }
        if !vulkanEvidence.isEmpty, !hasCompleteVulkanRuntime {
            appendLimitation("incomplete-vulkan-runtime")
        }
        if !vulkanRendererEvidence.isEmpty,
           !hasCompleteVulkanDirect3D9Renderer(evidence: vulkanRendererEvidence),
           !hasCompleteVulkanDirect3D11Renderer(evidence: vulkanRendererEvidence) {
            appendLimitation("incomplete-vulkan-direct3d-renderer")
        }
        if wineRoot != nil {
            if wineRootGnuTLSEvidence.isEmpty {
                appendLimitation("missing-wine-gnutls-runtime")
            }
            if wineRootFreeTypeEvidence.isEmpty {
                appendLimitation("missing-wine-freetype-runtime")
            }
            if wineRootVulkanLoaderEvidence.isEmpty {
                appendLimitation("missing-wine-vulkan-loader")
            }
            if wineRootMoltenVKEvidence.isEmpty {
                appendLimitation("missing-wine-moltenvk-runtime")
            }
            if wineRootVulkanICDEvidence.isEmpty {
                appendLimitation("missing-wine-vulkan-icd")
            }
        }
        if !hasD3DMetalDirect3DRenderer && !hasVulkanDirect3DRenderer && !isBuiltWithoutVulkan {
            appendLimitation("missing-direct3d-renderer")
        }
        let backend: WindowsRuntimeCapability.GraphicsBackend
        if hasD3DMetalDirect3DRenderer {
            backend = .d3dMetal
        } else if hasVulkanDirect3DRenderer {
            backend = .moltenVKOrVulkan
        } else if isBuiltWithoutVulkan {
            backend = .unsupportedByMetadata
        } else {
            backend = .unknown
        }

        var supportedDirect3DGenerationsByBackend:
            [WindowsRuntimeCapability.GraphicsBackend: Set<WindowsRuntimeCapability.Direct3DGeneration>] = [:]
        if hasD3DMetalDirect3DRenderer {
            var generations = Set<WindowsRuntimeCapability.Direct3DGeneration>()
            if appleD3DMetalInspection.supportsDirect3D11 {
                generations.insert(.d3d11)
            }
            if appleD3DMetalInspection.supportsDirect3D12 {
                generations.insert(.d3d12)
            }
            if hasCompleteDXMTLaunchPayload {
                generations.insert(.d3d11)
            }
            supportedDirect3DGenerationsByBackend[.d3dMetal] = generations
        }
        if hasVulkanDirect3DRenderer {
            var generations = Set<WindowsRuntimeCapability.Direct3DGeneration>()
            if hasVulkanDirect3D9Renderer, !isBuiltWithoutVulkan {
                generations.insert(.d3d9)
            }
            if hasVulkanDirect3D11Renderer, !isBuiltWithoutVulkan {
                generations.insert(.d3d11)
            }
            supportedDirect3DGenerationsByBackend[.moltenVKOrVulkan] = generations
        }
        let availableGraphicsBackends = Set(supportedDirect3DGenerationsByBackend.keys)
        let supportedDirect3DGenerations = Set(
            supportedDirect3DGenerationsByBackend.values.flatMap { $0 }
        )

        return WindowsRuntimeCapability(
            executableURL: executable,
            graphicsBackend: backend,
            evidence: evidence,
            limitations: limitations,
            availableGraphicsBackends: availableGraphicsBackends,
            supportedDirect3DGenerations: supportedDirect3DGenerations,
            supportedDirect3DGenerationsByBackend: supportedDirect3DGenerationsByBackend,
            rendererRuntimeGates: rendererRuntimeGates
        )
    }

    private nonisolated static func gateFailureLimitation(
        for gate: WindowsRendererRuntimeGateStatus
    ) -> String? {
        switch gate {
        case .verified:
            nil
        case .failed:
            "dxvk-runtime-gate-failed"
        case .unverified:
            "dxvk-runtime-gate-unverified"
        }
    }

    private nonisolated static func runnerCapabilitySearchRoots(
        for executable: URL,
        fileManager: FileManager
    ) -> [URL] {
        SafeProcessRunner.runtimeLayoutSearchRoots(
            for: executable,
            fileManager: fileManager
        )
    }

    private nonisolated static func existingCapabilityEvidence(
        roots: [URL],
        relativePaths: [String],
        fileManager: FileManager
    ) -> [String] {
        var evidence: [String] = []
        var seen = Set<String>()
        for root in roots {
            for relativePath in relativePaths {
                let candidate = root.appending(path: relativePath)
                guard safeExistingCapabilityPath(candidate, fileManager: fileManager) else {
                    continue
                }
                let standardized = candidate.standardizedFileURL.path
                if seen.insert(standardized).inserted {
                    evidence.append(relativePath)
                }
            }
        }
        return evidence
    }

    private nonisolated static func steamUIConformanceEvidence(
        roots: [URL],
        fileManager: FileManager
    ) -> (evidence: [String], limitations: [String]) {
        let markerNames = [
            "STEAM-UI-CONFORMANCE.json",
            "steam-ui-conformance.json",
            "SteamUIConformance.json"
        ]
        var evidence: [String] = []
        var limitations: [String] = []
        var seen = Set<String>()
        for root in roots {
            for markerName in markerNames {
                let marker = root.appending(path: markerName)
                let markerPath = marker.standardizedFileURL.path
                guard seen.insert(markerPath).inserted,
                      safeExistingCapabilityPath(marker, fileManager: fileManager),
                      let data = try? Data(contentsOf: marker, options: .mappedIfSafe) else {
                    continue
                }
                let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
                let normalized = text
                    .replacingOccurrences(of: "_", with: "-")
                    .lowercased()
                if normalized.contains("failed-known-bad") ||
                    normalized.contains("steam-ui-failed-known-bad") {
                    evidence.append("\(markerName): steam_ui_status=failed_known_bad")
                    limitations.append("steam-ui-failed-known-bad")
                } else if normalized.contains("known-good-control") ||
                            normalized.contains("known-good") {
                    evidence.append("\(markerName): steam_ui_status=known_good_control")
                } else {
                    evidence.append("\(markerName): steam_ui_status=unclassified")
                }
            }
        }
        return (evidence, limitations)
    }

    private struct AppleD3DMetalRuntimeInspection: Sendable {
        var evidence: [String]
        var supportsDirect3D11: Bool
        var supportsDirect3D12: Bool
        var supportsCompleteLaunchPayload: Bool
    }

    private struct D3DMetalFrameworkVersion: Sendable {
        var shortVersion: String
        var bundleVersion: String
    }

    private nonisolated static func inspectAppleD3DMetalRuntime(
        roots: [URL],
        supplementalRendererRoots: [URL],
        fileManager: FileManager
    ) -> AppleD3DMetalRuntimeInspection {
        let rendererLayouts = [
            "lib64/apple_gptk",
            "Frameworks/renderer/d3dmetal",
            "Contents/Frameworks/renderer/d3dmetal"
        ]
        let frameworkInfoPath = "external/D3DMetal.framework/Resources/Info.plist"
        let evidenceRelativePaths = [
            "external/D3DMetal.framework/D3DMetal",
            frameworkInfoPath,
            "external/D3DMetal.framework/Resources/default.metallib",
            "external/D3DMetal.framework/Resources/libdxccontainer.dylib",
            "external/D3DMetal.framework/Resources/libdxcompiler.dylib",
            "external/D3DMetal.framework/Resources/libdxilconv.dylib",
            "external/D3DMetal.framework/Resources/libmetalirconverter.dylib",
            "external/libd3dshared.dylib",
            "wine/x86_64-unix/d3d9.so",
            "wine/x86_64-unix/d3d10.so",
            "wine/x86_64-unix/d3d11.so",
            "wine/x86_64-unix/d3d12.so",
            "wine/x86_64-unix/dxgi.so",
            "wine/x86_64-unix/nvapi.so",
            "wine/x86_64-unix/nvapi64.so",
            "wine/x86_64-unix/nvngx-on-metalfx.so",
            "wine/x86_64-windows/d3d9.dll",
            "wine/x86_64-windows/d3d10.dll",
            "wine/x86_64-windows/d3d11.dll",
            "wine/x86_64-windows/d3d12.dll",
            "wine/x86_64-windows/dxgi.dll",
            "wine/x86_64-windows/nvapi.dll",
            "wine/x86_64-windows/nvapi64.dll",
            "wine/x86_64-windows/nvngx-on-metalfx.dll"
        ]
        var evidence: [String] = []
        var seenRendererRoots = Set<String>()
        var seenEvidence = Set<String>()
        var supportsDirect3D11 = false
        var supportsDirect3D12 = false
        var supportsCompleteLaunchPayload = false

        let rendererCandidates = roots.flatMap { root in
            rendererLayouts.map { layout in
                (label: layout, root: root.appending(path: layout, directoryHint: .isDirectory))
            }
        } + supplementalRendererRoots.enumerated().map { index, root in
            (label: "managed-supplemental-d3dmetal-\(index)", root: root)
        }

        for candidate in rendererCandidates {
                let layout = candidate.label
                let rendererRoot = candidate.root
                guard seenRendererRoots.insert(rendererRoot.standardizedFileURL.path).inserted else {
                    continue
                }

                let presentPaths = Set(evidenceRelativePaths.filter { relativePath in
                    D3DMetalRendererPayloadContract.isSafePayloadPath(
                        relativePath,
                        at: rendererRoot,
                        fileManager: fileManager
                    )
                })
                guard !presentPaths.isEmpty else { continue }

                for relativePath in evidenceRelativePaths where presentPaths.contains(relativePath) {
                    let evidencePath = "\(layout)/\(relativePath)"
                    if seenEvidence.insert(evidencePath).inserted {
                        evidence.append(evidencePath)
                    }
                }

                let frameworkVersion = presentPaths.contains(frameworkInfoPath)
                    ? d3dMetalFrameworkVersion(
                        infoPlist: rendererRoot.appending(path: frameworkInfoPath),
                        fileManager: fileManager
                    )
                    : nil
                if let frameworkVersion {
                    let versionEvidence = "D3DMetal.framework version \(frameworkVersion.shortVersion) (build \(frameworkVersion.bundleVersion))"
                    if seenEvidence.insert(versionEvidence).inserted {
                        evidence.append(versionEvidence)
                    }
                }

                let supportsDirect3D11InCandidate = D3DMetalRendererPayloadContract.isUsable(
                    for: .direct3D11Family,
                    at: rendererRoot,
                    fileManager: fileManager
                )
                let supportsDirect3D12InCandidate = frameworkVersion != nil &&
                    D3DMetalRendererPayloadContract.isUsable(
                        for: .direct3D12,
                        at: rendererRoot,
                        fileManager: fileManager
                    )
                if supportsDirect3D11InCandidate {
                    supportsDirect3D11 = true
                }
                if supportsDirect3D12InCandidate {
                    supportsDirect3D12 = true
                }
                if supportsDirect3D11InCandidate && supportsDirect3D12InCandidate {
                    supportsCompleteLaunchPayload = true
                }
        }

        return AppleD3DMetalRuntimeInspection(
            evidence: evidence,
            supportsDirect3D11: supportsDirect3D11,
            supportsDirect3D12: supportsDirect3D12,
            supportsCompleteLaunchPayload: supportsCompleteLaunchPayload
        )
    }

    private nonisolated static func d3dMetalFrameworkVersion(
        infoPlist: URL,
        fileManager: FileManager
    ) -> D3DMetalFrameworkVersion? {
        guard safeExistingCapabilityPath(infoPlist, fileManager: fileManager),
              let data = try? Data(contentsOf: infoPlist, options: .mappedIfSafe),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              dictionary["CFBundleExecutable"] as? String == "D3DMetal",
              let shortVersion = (dictionary["CFBundleShortVersionString"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !shortVersion.isEmpty,
              let bundleVersion = (dictionary["CFBundleVersion"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleVersion.isEmpty else {
            return nil
        }
        let majorDigits = shortVersion.prefix(while: \Character.isNumber)
        guard let majorVersion = Int(majorDigits), majorVersion >= 4 else {
            return nil
        }
        return D3DMetalFrameworkVersion(
            shortVersion: shortVersion,
            bundleVersion: bundleVersion
        )
    }

    private nonisolated static func hasCompleteDXMTRuntime(evidence: [String]) -> Bool {
        let hasUnixWineMetal = evidence.contains {
            $0.hasSuffix("renderer/dxmt/wine/x86_64-unix/winemetal.so")
        }
        let hasWindows64D3D11 = evidence.contains {
            $0.hasSuffix("renderer/dxmt/wine/x86_64-windows/d3d11.dll")
        }
        let hasWindows64DXGI = evidence.contains {
            $0.hasSuffix("renderer/dxmt/wine/x86_64-windows/dxgi.dll")
        }
        let hasWindows64WineMetal = evidence.contains {
            $0.hasSuffix("renderer/dxmt/wine/x86_64-windows/winemetal.dll")
        }
        let hasWindows32D3D11 = evidence.contains {
            $0.hasSuffix("renderer/dxmt/wine/i386-windows/d3d11.dll")
        }
        let hasWindows32DXGI = evidence.contains {
            $0.hasSuffix("renderer/dxmt/wine/i386-windows/dxgi.dll")
        }
        let hasWindows32WineMetal = evidence.contains {
            $0.hasSuffix("renderer/dxmt/wine/i386-windows/winemetal.dll")
        }
        return hasUnixWineMetal &&
            hasWindows64D3D11 &&
            hasWindows64DXGI &&
            hasWindows64WineMetal &&
            hasWindows32D3D11 &&
            hasWindows32DXGI &&
            hasWindows32WineMetal
    }

    private nonisolated static func hasCompleteVulkanDirect3D9Renderer(evidence: [String]) -> Bool {
        let hasWindows64D3D9 = evidence.contains { $0.hasSuffix("x86_64-windows/d3d9.dll") }
        let hasWindows32D3D9 = evidence.contains { $0.hasSuffix("i386-windows/d3d9.dll") }
        return hasWindows64D3D9 && hasWindows32D3D9
    }

    private nonisolated static func hasCompleteVulkanDirect3D11Renderer(evidence: [String]) -> Bool {
        let hasWindows64D3D11 = evidence.contains { $0.hasSuffix("x86_64-windows/d3d11.dll") }
        let hasWindows64DXGI = evidence.contains { $0.hasSuffix("x86_64-windows/dxgi.dll") }
        let hasWindows32D3D11 = evidence.contains { $0.hasSuffix("i386-windows/d3d11.dll") }
        let hasWindows32DXGI = evidence.contains { $0.hasSuffix("i386-windows/dxgi.dll") }
        return hasWindows64D3D11 &&
            hasWindows64DXGI &&
            hasWindows32D3D11 &&
            hasWindows32DXGI
    }

    private nonisolated static func activeWineD3DMetalOverlayEvidence(
        in wineRoot: URL,
        fileManager: FileManager
    ) -> [String] {
        let markers = [
            "D3DMetal",
            "D3DMetalWineThread",
            "libd3dshared",
            "MetalFX",
            "nvngx-on-metalfx"
        ]
        let relativePaths = [
            "lib/external/D3DMetal.framework/D3DMetal",
            "lib/wine/x86_64-unix/d3d10.so",
            "lib/wine/x86_64-unix/d3d11.so",
            "lib/wine/x86_64-unix/d3d12.so",
            "lib/wine/x86_64-unix/dxgi.so",
            "lib/wine/x86_64-unix/nvapi.so",
            "lib/wine/x86_64-unix/nvapi64.so",
            "lib/wine/x86_64-unix/nvngx-on-metalfx.so",
            "lib/wine/x86_64-unix/libd3dshared.dylib",
            "lib/wine/x86_64-windows/d3d10.dll",
            "lib/wine/x86_64-windows/d3d11.dll",
            "lib/wine/x86_64-windows/d3d12.dll",
            "lib/wine/x86_64-windows/dxgi.dll",
            "lib/wine/x86_64-windows/nvapi.dll",
            "lib/wine/x86_64-windows/nvapi64.dll",
            "lib/wine/x86_64-windows/nvngx-on-metalfx.dll"
        ]
        return relativePaths.filter { relativePath in
            let candidate = wineRoot.appending(path: relativePath)
            guard safeExistingCapabilityPath(candidate, fileManager: fileManager) else { return false }
            if relativePath.hasSuffix("D3DMetal.framework/D3DMetal") ||
                relativePath.hasSuffix("libd3dshared.dylib") ||
                relativePath.contains("nvngx-on-metalfx") {
                return true
            }
            return binaryFileContainsAnyUTF8(candidate, markers: markers)
        }
    }

    private nonisolated static func safeExistingCapabilityPath(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let resolved = url.resolvingSymlinksInPath()
                let resolvedValues = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                return resolvedValues.isDirectory == true || resolvedValues.isRegularFile == true
            }
            return values.isDirectory == true || values.isRegularFile == true
        } catch {
            return false
        }
    }

    private nonisolated static func binaryFile(_ url: URL, containsUTF8 marker: String) -> Bool {
        guard let markerData = marker.data(using: .utf8),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return false
        }
        return data.range(of: markerData) != nil
    }

    private nonisolated static func binaryFileContainsAnyUTF8(_ url: URL, markers: [String]) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return false
        }
        return markers.contains { marker in
            guard let markerData = marker.data(using: .utf8) else { return false }
            return data.range(of: markerData) != nil
        }
    }

    private nonisolated static func hasSteamWebHelperRootScopedExecutableArgumentPolicy(
        in wineRoot: URL,
        fileManager: FileManager
    ) -> Bool {
        steamWebHelperRootScopedArgumentPolicyKernelbaseRelativePaths.allSatisfy { relativePath in
            let kernelbase = wineRoot.appending(path: relativePath)
            return FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                from: wineRoot,
                to: kernelbase,
                fileManager: fileManager
            ) && FileSystemItemPolicy.isRegularNonSymlinkFile(
                kernelbase,
                fileManager: fileManager
            ) && binaryFile(
                kernelbase,
                containsAllUTF8OrUTF16LittleEndian:
                    steamWebHelperRootScopedArgumentPolicyMarkers
            )
        }
    }

    private nonisolated static func binaryFile(
        _ url: URL,
        containsAllUTF8OrUTF16LittleEndian markers: [String]
    ) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return false
        }
        return markers.allSatisfy { marker in
            [String.Encoding.utf8, .utf16LittleEndian].contains { encoding in
                guard let markerData = marker.data(using: encoding) else {
                    return false
                }
                return data.range(of: markerData) != nil
            }
        }
    }

    private nonisolated static func runnerMetadataLimitations(
        roots: [URL],
        fileManager: FileManager
    ) -> [String] {
        var limitations: [String] = []
        var seen = Set<String>()
        for root in roots {
            let metadata = root.appending(path: "BUILD-METADATA.md")
            guard safeExistingCapabilityPath(metadata, fileManager: fileManager) else {
                continue
            }
            let text: String
            do {
                let data = try Data(contentsOf: metadata)
                text = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
            } catch {
                if seen.insert("metadata-read-failed").inserted {
                    limitations.append("metadata-read-failed")
                }
                continue
            }
            let lowercased = text.lowercased()
            let builtWithoutVulkan = lowercased.contains("--without-vulkan") ||
                lowercased.contains("without vulkan support") ||
                lowercased.contains("built without vulkan") ||
                lowercased.contains("was built without vulkan")
            let builtWithoutD3DMetal = lowercased.contains("without apple gptk/d3dmetal") ||
                lowercased.contains("without apple gptk") ||
                lowercased.contains("without d3dmetal")
            let builtWithoutGnuTLS = lowercased.contains("--without-gnutls") ||
                lowercased.contains("without gnutls") ||
                lowercased.contains("does not include gnutls/schannel") ||
                lowercased.contains("does not include gnutls") ||
                lowercased.contains("no gnutls") ||
                lowercased.contains("schannel support can fail")
            let steamCEFRendererValidationFailed =
                lowercased.contains("steam-cef-webhelper-renderer-validation-failed") ||
                lowercased.contains("steam cef/webhelper ui validation: failed") ||
                lowercased.contains("steam cef webhelper ui validation failed") ||
                lowercased.contains("windows steam cef/webhelper rendering failed")
            if builtWithoutVulkan, builtWithoutD3DMetal {
                if seen.insert("built-without-vulkan-or-d3dmetal").inserted {
                    limitations.append("built-without-vulkan-or-d3dmetal")
                }
            } else if builtWithoutVulkan,
                      seen.insert("built-without-vulkan").inserted {
                limitations.append("built-without-vulkan")
            }
            if builtWithoutGnuTLS,
               seen.insert("built-without-gnutls-or-schannel").inserted {
                limitations.append("built-without-gnutls-or-schannel")
            }
            if steamCEFRendererValidationFailed,
               seen.insert("steam-cef-webhelper-renderer-validation-failed").inserted {
                limitations.append("steam-cef-webhelper-renderer-validation-failed")
            }
        }
        return limitations
    }

    private nonisolated static func dxvkRuntimeGate(
        roots: [URL],
        fileManager: FileManager
    ) -> WindowsRendererRuntimeGateStatus {
        for root in roots {
            let sbomURL = root.appending(path: "RuntimeSBOM.json")
            guard FileSystemItemPolicy.isRegularNonSymlinkFile(
                sbomURL,
                fileManager: fileManager
            ),
            let values = try? sbomURL.resourceValues(forKeys: [.fileSizeKey]),
            let byteCount = values.fileSize,
            (1...1_048_576).contains(byteCount),
            let data = try? Data(contentsOf: sbomURL, options: .mappedIfSafe),
            data.count == byteCount,
            let sbom = try? JSONDecoder().decode(
                WindowsRendererRuntimeGateSBOM.self,
                from: data
            ) else {
                continue
            }
            let contentSHA256ByPath = Dictionary(
                sbom.hostSupportPayload.map { ($0.path, $0.contentSHA256) },
                uniquingKeysWith: { first, _ in first }
            )
            let isFailedGeneration =
                failedDXVKRuntimeGatePayloadSHA256ByPath.allSatisfy {
                    path, expectedSHA256 in
                    contentSHA256ByPath[path] == expectedSHA256
                }
            guard isFailedGeneration else { continue }
            return .failed(
                evidence:
                    "locked DXVK/MoltenVK component generation matched the actual-device gate",
                technicalDetail:
                    "DXVK reached the bundled MoltenVK device with geometryShader=0; CreateDXGIFactory1 returned 0x80004005"
            )
        }
        return .unverified(
            technicalDetail:
                "no authenticated successful DXVK DXGI device gate exists for this Runtime generation"
        )
    }

    private nonisolated static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var output: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            if seen.insert(path).inserted {
                output.append(url)
            }
        }
        return output
    }

    private nonisolated static func wineLibraryDirectory(for executable: URL, fileManager: FileManager) -> URL? {
        let components = executable.pathComponents
        if let binIndex = components.lastIndex(of: "bin"), binIndex > 0 {
            let wineRoot = URL(fileURLWithPath: NSString.path(withComponents: Array(components[0..<binIndex])))
            let lib = wineRoot.appending(path: "lib", directoryHint: .isDirectory)
            if FileSystemItemPolicy.isNonSymlinkDirectory(lib, fileManager: fileManager) {
                return lib
            }
        }
        if let resourcesIndex = components.lastIndex(of: "Resources") {
            let lib = URL(fileURLWithPath: NSString.path(withComponents: Array(components[0...resourcesIndex])))
                .appending(path: "wine/lib", directoryHint: .isDirectory)
            if FileSystemItemPolicy.isNonSymlinkDirectory(lib, fileManager: fileManager) {
                return lib
            }
        }
        return nil
    }

    private nonisolated static func wineRuntimeRoot(for executable: URL, fileManager: FileManager) -> URL? {
        if let binDirectory = wineBinDirectory(for: executable) {
            let wineRoot = binDirectory.deletingLastPathComponent()
            if wineRoot.lastPathComponent == "wine",
               FileSystemItemPolicy.isNonSymlinkDirectory(wineRoot, fileManager: fileManager) {
                return wineRoot
            }
        }
        return wineLibraryDirectory(for: executable, fileManager: fileManager)?
            .deletingLastPathComponent()
    }

    nonisolated static func wineRuntimeIntegrityMessage(
        for executable: URL,
        fileManager: FileManager = .default
    ) -> String? {
        guard let wineLib = wineLibraryDirectory(for: executable, fileManager: fileManager) else {
            return nil
        }
        let wineModuleDirectory = wineLib.appending(path: "wine", directoryHint: .isDirectory)
        guard FileSystemItemPolicy.isNonSymlinkDirectory(wineModuleDirectory, fileManager: fileManager) else {
            return nil
        }

        let ntdllCandidates = [
            wineModuleDirectory.appending(path: "ntdll.so"),
            wineModuleDirectory.appending(path: "x86_64-unix/ntdll.so"),
            wineModuleDirectory.appending(path: "i386-unix/ntdll.so"),
            wineModuleDirectory.appending(path: "aarch64-unix/ntdll.so")
        ]
        if ntdllCandidates.contains(where: {
            FileSystemItemPolicy.isRegularNonSymlinkFile($0, fileManager: fileManager)
        }) {
            return nil
        }

        let modularWineMarkers = [
            "x86_64-unix",
            "i386-unix",
            "aarch64-unix",
            "x86_64-windows",
            "i386-windows",
            "aarch64-windows"
        ]
        let hasModularWineLayout = modularWineMarkers.contains {
            FileSystemItemPolicy.isNonSymlinkDirectory(
                wineModuleDirectory.appending(path: $0, directoryHint: .isDirectory),
                fileManager: fileManager
            )
        }
        guard hasModularWineLayout else {
            return nil
        }

        return String(
            format: incompleteWineRuntimeMessageFormat,
            wineModuleDirectory.path
        )
    }

    private nonisolated static func validateWineRuntimeIntegrity(
        for executable: URL,
        fileManager: FileManager
    ) throws {
        if let message = wineRuntimeIntegrityMessage(for: executable, fileManager: fileManager) {
            throw WindowsRuntimeServiceError.invalidSelection(message)
        }
    }

    private nonisolated static let incompleteWineRuntimeMessageFormat =
        "앱에 포함된 ForgePlay Runtime에 핵심 파일(ntdll.so)이 없습니다: %@. Runtime이 온전히 포함된 최신 ForgePlay 빌드를 다시 설치하세요."

    nonisolated static func containsEvaluationRedistStrict(in root: URL, fileManager: FileManager) throws -> Bool {
        try evaluationRedistLibraryStrict(in: root, fileManager: fileManager) != nil
    }

    private nonisolated static func evaluationRedistLibraryStrict(in root: URL, fileManager: FileManager) throws -> URL? {
        guard try isExistingNonSymlinkDirectory(
            root,
            fileManager: fileManager,
            scanFailed: WindowsRuntimeServiceError.supplementalRedistScanFailed
        ) else {
            return nil
        }

        let direct = root.appending(path: AppleSupplementalRendererLayout.redistLibraryRelativePath, directoryHint: .isDirectory)
        if try isValidEvaluationRedistLibrary(direct, fileManager: fileManager) {
            return direct
        }

        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw WindowsRuntimeServiceError.supplementalRedistScanFailed(root, CocoaError(.fileReadUnknown))
        }

        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - root.pathComponents.count
            if depth > AppleSupplementalRendererLayout.maxRedistSearchDepth {
                enumerator.skipDescendants()
                continue
            }

            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch {
                throw WindowsRuntimeServiceError.supplementalRedistScanFailed(root, error)
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isDirectory == true else { continue }
            guard url.lastPathComponent == "redist" else { continue }

            let redistLib = url.appending(path: "lib", directoryHint: .isDirectory)
            if try isValidEvaluationRedistLibrary(redistLib, fileManager: fileManager) {
                return redistLib
            }
        }
        if let enumerationError {
            throw WindowsRuntimeServiceError.supplementalRedistScanFailed(root, enumerationError)
        }

        return nil
    }

    private nonisolated static func isValidEvaluationRedistLibrary(_ redistLib: URL, fileManager: FileManager) throws -> Bool {
        guard try isExistingNonSymlinkDirectory(
            redistLib,
            fileManager: fileManager,
            scanFailed: WindowsRuntimeServiceError.supplementalRedistScanFailed
        ) else { return false }
        guard try isExistingNonSymlinkDirectory(
            redistLib.appending(path: AppleSupplementalRendererLayout.redistExternalFrameworkRelativePath),
            fileManager: fileManager,
            scanFailed: WindowsRuntimeServiceError.supplementalRedistScanFailed
        ) else { return false }
        return try isExistingNonSymlinkDirectory(
            redistLib.appending(path: AppleSupplementalRendererLayout.redistWineRelativePath, directoryHint: .isDirectory),
            fileManager: fileManager,
            scanFailed: WindowsRuntimeServiceError.supplementalRedistScanFailed
        )
    }

    nonisolated static func validateSupplementalRedistLinks(
        in root: URL,
        fileManager: FileManager
    ) throws {
        try validateInternalRelativeLinks(
            in: root,
            fileManager: fileManager,
            scanFailed: { WindowsRuntimeServiceError.supplementalRedistScanFailed($0, $1) },
            unsafeSymlink: WindowsRuntimeServiceError.unsafeSupplementalRedistSymlink,
            unsafeHardlink: WindowsRuntimeServiceError.unsafeSupplementalRedistHardlink
        )
    }

    private nonisolated static func validateInternalRelativeLinks(
        in root: URL,
        fileManager: FileManager,
        scanFailed: (URL, Error) -> WindowsRuntimeServiceError,
        unsafeSymlink: (URL) -> WindowsRuntimeServiceError,
        unsafeHardlink: (URL) -> WindowsRuntimeServiceError
    ) throws {
        do {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(root, fileManager: fileManager)
        } catch FileSystemItemPolicyError.notNonSymlinkDirectory {
            throw unsafeSymlink(root)
        } catch {
            throw scanFailed(root, error)
        }
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .linkCountKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw scanFailed(root, CocoaError(.fileReadUnknown))
        }

        for case let item as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .linkCountKey])
            } catch {
                throw scanFailed(root, error)
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                let target: String
                do {
                    target = try fileManager.destinationOfSymbolicLink(atPath: item.path)
                } catch {
                    throw scanFailed(root, error)
                }
                guard !target.hasPrefix("/") else {
                    throw unsafeSymlink(item)
                }
                let resolvedTarget = URL(
                    fileURLWithPath: target,
                    relativeTo: item.deletingLastPathComponent()
                ).standardizedFileURL
                guard pathIsInsideRoot(resolvedTarget.path, root: root) else {
                    throw unsafeSymlink(item)
                }
                continue
            }
            if values.isRegularFile == true, (values.linkCount ?? 1) != 1 {
                throw unsafeHardlink(item)
            }
        }
        if let enumerationError {
            throw scanFailed(root, enumerationError)
        }
    }

    private nonisolated static func isExistingNonSymlinkDirectory(
        _ url: URL,
        fileManager: FileManager,
        scanFailed: (URL, Error) -> WindowsRuntimeServiceError = WindowsRuntimeServiceError.sourceScanFailed
    ) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true && values.isSymbolicLink != true
        } catch {
            throw scanFailed(url, error)
        }
    }

    private nonisolated static func runtimeExecutableValidationMessage(
        _ url: URL,
        requireExecutable: Bool,
        fileManager: FileManager
    ) -> String? {
        guard url.lastPathComponent == "wine" else {
            return "ForgePlay Runtime 실행 파일 경로가 올바르지 않습니다: \(url.path)"
        }
        if !FileSystemItemPolicy.isRegularNonSymlinkFile(url, fileManager: fileManager) {
            do {
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
            } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
                return "실행기 파일 정보를 읽지 못했습니다: \(url.path). \(message)"
            } catch {
                return "실행기는 symlink/hardlink가 아닌 일반 실행 파일이어야 합니다: \(url.path)"
            }
        }
        if requireExecutable, !fileManager.isExecutableFile(atPath: url.path) {
            return "실행 파일 권한이 없는 실행기입니다: \(url.path)"
        }
        return nil
    }

    private nonisolated static func requireDiskImageFile(_ url: URL, fileManager: FileManager) throws {
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw WindowsRuntimeServiceError.invalidSelection("DMG 파일 정보를 읽지 못했습니다: \(url.path). \(message)")
        } catch {
            throw WindowsRuntimeServiceError.invalidSelection("DMG는 symlink/hardlink가 아닌 일반 파일이어야 합니다: \(url.path)")
        }
    }

    private nonisolated static func pathIsInsideRoot(_ candidate: String, root: URL) -> Bool {
        let candidatePath = URL(fileURLWithPath: candidate).standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if candidatePath == rootPath {
            return true
        }
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(rootPrefix)
    }

    private nonisolated static func probeLooksUsable(_ result: ProcessRunResult) -> Bool {
        result.succeeded
    }

}

enum WindowsRuntimeServiceError: LocalizedError {
    case invalidSelection(String)
    case probeFailed(ProcessRunResult)
    case missingSteamRendererCapability(WindowsRuntimeCapability)
    case sourceScanFailed(URL, Error)
    case supplementalRedistScanFailed(URL, Error)
    case unsafeSupplementalRedistSymlink(URL)
    case unsafeSupplementalRedistHardlink(URL)
    case payloadReplacementRollbackFailed(destination: URL, backup: URL, originalError: Error, rollbackError: Error)

    var errorDescription: String? {
        switch self {
        case .invalidSelection(let message):
            "ForgePlay Runtime을 확인할 수 없습니다. \(message)"
        case .probeFailed(let result):
            "ForgePlay Runtime을 실행해 확인하지 못했습니다. 로그를 확인하세요: \(result.stderrLog.path)"
        case .missingSteamRendererCapability(let capability):
            "\(capability.userMessage) Windows용 Steam을 실행하려면 D3DMetal 또는 Vulkan/DXVK 렌더러를 제공하는 ForgePlay Runtime이 필요합니다."
        case .sourceScanFailed(let directory, let error):
            "Apple 보조 렌더러 입력을 검사하지 못했습니다: \(directory.path). \(forgePlayTechnicalErrorSummary(error))"
        case .supplementalRedistScanFailed(let directory, let error):
            "Evaluation environment redist를 검사하지 못했습니다: \(directory.path). \(forgePlayTechnicalErrorSummary(error))"
        case .unsafeSupplementalRedistSymlink(let url):
            "Evaluation environment redist 안의 symlink가 redist 폴더 밖을 가리킵니다: \(url.path)"
        case .unsafeSupplementalRedistHardlink(let url):
            "Evaluation environment redist 안의 hardlink 파일을 제거해야 합니다: \(url.path)"
        case .payloadReplacementRollbackFailed(let destination, let backup, let originalError, let rollbackError):
            "Apple 보조 렌더러 교체에 실패했고 기존 파일을 되돌리지 못했습니다: \(destination.path). 백업 위치: \(backup.path). 원인: \(forgePlayTechnicalErrorSummary(originalError)). 복구 오류: \(forgePlayTechnicalErrorSummary(rollbackError))"
        }
    }
}

struct WindowsRuntimePreparedExecutionControlV1: Sendable {
    let records: WindowsExecutionValidatedCapabilityRecords
    let profile: WindowsPreparedHelperExecutionProfile
    let neutralEnvironmentProjection:
        WindowsRendererNeutralEnvironmentProjection
    let authority: WindowsExecutionCapabilityAuthority
    let cleanupDeadlineMonotonicNanoseconds: UInt64
}

extension WindowsRuntimeService {
    /// Prepares the ForgePlay-owned control plane without launching a process.
    /// The single-consume step is last among fallible input validations, so a
    /// malformed environment or profile cannot burn a valid descriptor.
    nonisolated static func prepareWindowsExecutionControl(
        descriptorData: Data,
        rendererSnapshotData: Data,
        nowMonotonicNanoseconds: UInt64,
        runtimeManifest: WindowsRuntimeExecutionManifestV1,
        providerRegistry: WindowsExecutionProviderRegistry,
        environmentCatalog: WindowsRendererEnvironmentCatalog,
        baseEnvironment: [String: String],
        consumeRegistry: WindowsExecutionSingleConsumeRegistry
    ) throws -> WindowsRuntimePreparedExecutionControlV1 {
        try providerRegistry.validateFrozenFingerprint()
        let decodedDescriptor = try WindowsExecutionLaunchDescriptorV1.decode(
            descriptorData,
            nowMonotonicNanoseconds: nowMonotonicNanoseconds
        )
        _ = try WindowsHelperExecutionProfile(
            executionMode: decodedDescriptor.executionMode,
            rendererRequirement: decodedDescriptor.rendererRequirement,
            lifecycleKind: decodedDescriptor.lifecycleKind,
            servicePersistence: decodedDescriptor.servicePersistence
        )
        let projection = try WindowsRendererNeutralEnvironmentProjection
            .capture(
                catalog: environmentCatalog,
                environment: baseEnvironment
            )
        _ = try projection.applying(to: baseEnvironment)

        let deadlineMilliseconds = UInt64(
            decodedDescriptor.cleanupDeadlineMilliseconds
        )
        let deadlineDelta = deadlineMilliseconds
            .multipliedReportingOverflow(by: 1_000_000)
        let absoluteDeadline = nowMonotonicNanoseconds
            .addingReportingOverflow(deadlineDelta.partialValue)
        guard !deadlineDelta.overflow, !absoluteDeadline.overflow else {
            throw WindowsExecutionContractError(
                reason: .lifecycleDeadlineExceeded,
                stage: .lifecycle,
                detail: "cleanup deadline arithmetic overflowed"
            )
        }

        let records = try WindowsExecutionCapabilityRecordTransaction
            .validateAndConsume(
                descriptorData: descriptorData,
                rendererSnapshotData: rendererSnapshotData,
                nowMonotonicNanoseconds: nowMonotonicNanoseconds,
                runtimeManifest: runtimeManifest,
                consumeRegistry: consumeRegistry
            )
        guard decodedDescriptor.recordSHA256.isAuthenticatedEqual(
            to: records.descriptor.recordSHA256
        ) else {
            throw WindowsExecutionContractError(
                reason: .capabilityFingerprintMismatch,
                stage: .descriptor,
                detail: "preflight and consumed descriptor records differ"
            )
        }
        let profile = try WindowsPreparedHelperExecutionProfile(
            descriptor: records.descriptor,
            bootstrap: records.bootstrap
        )
        let authority = try WindowsExecutionCapabilityAuthority(
            records: records,
            providerRegistry: providerRegistry,
            neutralEnvironmentProjection: projection,
            rendererNeutralBaseEnvironment: baseEnvironment
        )
        return WindowsRuntimePreparedExecutionControlV1(
            records: records,
            profile: profile,
            neutralEnvironmentProjection: projection,
            authority: authority,
            cleanupDeadlineMonotonicNanoseconds: absoluteDeadline.partialValue
        )
    }
}
