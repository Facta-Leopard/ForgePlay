import Foundation

struct SteamClientCompatibilityVerification: Hashable {
    enum Blocker: String, Hashable {
        case missingSteamNetworking
        case missingSteamTextRuntime
        case unsupportedSteamUIRenderer
        case activeD3DMetalOverlay
        case missingModernDirect3DRenderer
        case knownBadSteamUIConformance
        case unsupportedExternalApplicationRunner
    }

    var capability: WindowsRuntimeCapability
    var launchBlockers: [Blocker]
    var managedGameBlockers: [Blocker]

    var supportsNetworking: Bool {
        !launchBlockers.contains(.missingSteamNetworking)
    }

    var canLaunchWindowsSteam: Bool {
        launchBlockers.isEmpty
    }

    var canLaunchManagedSteamGames: Bool {
        managedGameBlockers.isEmpty
    }

    var userMessage: String {
        SteamClientCompatibilityVerifier.userMessage(for: self)
    }
}

struct SteamClientCompatibilityVerifier {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func verify(executable: URL) throws -> SteamClientCompatibilityVerification {
        let capability = WindowsRuntimeService.inspectRuntimeCapability(for: executable, fileManager: fileManager)
        return Self.verify(capability: capability)
    }

    func verify(capability: WindowsRuntimeCapability) -> SteamClientCompatibilityVerification {
        Self.verify(capability: capability)
    }

    static func verify(capability: WindowsRuntimeCapability) -> SteamClientCompatibilityVerification {
        let launchBlockers = steamLaunchBlockers(for: capability)
        return SteamClientCompatibilityVerification(
            capability: capability,
            launchBlockers: launchBlockers,
            managedGameBlockers: launchBlockers
        )
    }

    static func userMessage(for verification: SteamClientCompatibilityVerification) -> String {
        if let steamBlockerMessage = steamClientBlockerMessage(for: verification.capability) {
            return steamBlockerMessage
        }
        if verification.managedGameBlockers.contains(.missingModernDirect3DRenderer) {
            return verification.capability.userMessage
        }
        return WindowsRuntimeDisplayName.statusSummary(for: verification.capability)
    }

    static func steamClientBlockerMessage(for capability: WindowsRuntimeCapability) -> String? {
        if capability.isUnsupportedExternalApplicationRunner {
            return "다른 macOS 앱에 포함된 실행 파일은 ForgePlay 런타임으로 실행하거나 성공 판정에 사용할 수 없습니다. 앱에 포함된 ForgePlay Runtime을 사용하세요."
        }
        let limitations = Set(capability.limitations)
        if limitations.contains("steam-cef-child-window-metal-swapchain-unsupported"),
           isFatalSteamUIRendererLimitation(
            "steam-cef-child-window-metal-swapchain-unsupported",
            for: capability
        ) {
            return "앱에 포함된 ForgePlay Runtime의 Wine mac 드라이버는 Windows용 Steam WebHelper처럼 별도 프로세스가 만드는 CEF 자식 창 표면 렌더링을 지원하지 않습니다. 최신 ForgePlay 빌드로 업데이트하거나 앱을 다시 설치하세요."
        }
        if limitations.contains("active-d3dmetal-overlay-in-wine-modules"),
           isFatalSteamUIRendererLimitation(
            "active-d3dmetal-overlay-in-wine-modules",
            for: capability
        ) {
            return "앱에 포함된 ForgePlay Runtime의 기본 Wine 모듈 디렉터리에 D3DMetal 렌더러가 전역 오버레이되어 있습니다. 이 구조는 Steam WebHelper까지 D3DMetal/DXGI를 강제로 로드할 수 있으므로 Runtime 무결성 복구를 위해 앱을 다시 설치하세요."
        }
        if limitations.contains("missing-steam-cef-d3d9-renderer"),
           isFatalSteamUIRendererLimitation(
            "missing-steam-cef-d3d9-renderer",
            for: capability
        ) {
            return "앱에 포함된 ForgePlay Runtime은 이전 검사 기준의 D3D9 Steam CEF blocker를 기록하고 있습니다. 최신 ForgePlay 빌드로 업데이트하거나 앱을 다시 설치한 뒤 Steam 실행 경로를 다시 정비하세요."
        }
        if limitations.contains("missing-wine-freetype-runtime") {
            return "앱에 포함된 ForgePlay Runtime은 Windows용 Steam 설치와 UI 텍스트 렌더링에 필요한 FreeType 런타임이 Wine 루트에 없어 SteamSetup.exe 또는 Steam UI가 정상 실행될 수 없습니다."
        }
        if limitations.contains("steam-ui-failed-known-bad") {
            return "앱에 포함된 ForgePlay Runtime은 Windows Steam UI 적합성 검사에서 failed_known_bad로 분류되어 있으므로 Steam 실행 성공으로 판정하지 않습니다."
        }
        guard !supportsSteamClientNetworking(capability) else {
            return nil
        }
        if capability.supportsModernDirect3DGames,
           limitations.contains("missing-wine-gnutls-runtime") {
            return "앱에 포함된 ForgePlay Runtime은 Steam 로그인/업데이트에 필요한 GnuTLS/Schannel 런타임이 Wine 루트에 없어 Windows용 Steam을 실행할 수 없습니다."
        }
        if !capability.supportsModernDirect3DGames {
            return "앱에 포함된 ForgePlay Runtime은 Steam 로그인/업데이트에 필요한 GnuTLS/Schannel과 Windows용 Steam 및 Steam에서 실행할 Direct3D 게임에 필요한 D3DMetal/Vulkan 렌더러 payload 없이 빌드되어 사용할 수 없습니다."
        }
        return "앱에 포함된 ForgePlay Runtime은 Steam 로그인/업데이트에 필요한 GnuTLS/Schannel 없이 빌드되어 Windows용 Steam을 실행할 수 없습니다."
    }

    static func hasExplicitSteamUIBlocker(in limitations: [String]) -> Bool {
        let limitations = Set(limitations)
        return limitations.contains("steam-cef-child-window-metal-swapchain-unsupported") ||
            limitations.contains("active-d3dmetal-overlay-in-wine-modules") ||
            limitations.contains("missing-steam-cef-d3d9-renderer") ||
            limitations.contains("steam-ui-failed-known-bad")
    }

    static func hasExplicitSteamUIBlocker(in capability: WindowsRuntimeCapability) -> Bool {
        capability.isUnsupportedExternalApplicationRunner ||
            capability.limitations.contains { isFatalSteamUIRendererLimitation($0, for: capability) } ||
            capability.limitations.contains("steam-ui-failed-known-bad")
    }

    private static func isFatalSteamUIRendererLimitation(
        _ limitation: String,
        for capability: WindowsRuntimeCapability
    ) -> Bool {
        return limitation == "steam-cef-child-window-metal-swapchain-unsupported" ||
            limitation == "active-d3dmetal-overlay-in-wine-modules" ||
            limitation == "missing-steam-cef-d3d9-renderer"
    }

    private static func steamLaunchBlockers(for capability: WindowsRuntimeCapability) -> [SteamClientCompatibilityVerification.Blocker] {
        let limitations = Set(capability.limitations)
        var blockers: [SteamClientCompatibilityVerification.Blocker] = []
        if capability.isUnsupportedExternalApplicationRunner {
            blockers.append(.unsupportedExternalApplicationRunner)
        }
        if !supportsSteamClientNetworking(capability) {
            blockers.append(.missingSteamNetworking)
        }
        if limitations.contains("missing-wine-freetype-runtime") {
            blockers.append(.missingSteamTextRuntime)
        }
        if limitations.contains("steam-cef-child-window-metal-swapchain-unsupported"),
           isFatalSteamUIRendererLimitation(
            "steam-cef-child-window-metal-swapchain-unsupported",
            for: capability
        ) {
            blockers.append(.unsupportedSteamUIRenderer)
        }
        if limitations.contains("active-d3dmetal-overlay-in-wine-modules"),
           isFatalSteamUIRendererLimitation(
            "active-d3dmetal-overlay-in-wine-modules",
            for: capability
        ) {
            blockers.append(.activeD3DMetalOverlay)
        }
        if limitations.contains("missing-steam-cef-d3d9-renderer"),
           isFatalSteamUIRendererLimitation(
            "missing-steam-cef-d3d9-renderer",
            for: capability
        ) {
            blockers.append(.unsupportedSteamUIRenderer)
        }
        if limitations.contains("steam-ui-failed-known-bad") {
            blockers.append(.knownBadSteamUIConformance)
        }
        if !capability.supportsModernDirect3DGames {
            blockers.append(.missingModernDirect3DRenderer)
        }
        return blockers
    }

    private static func supportsSteamClientNetworking(_ capability: WindowsRuntimeCapability) -> Bool {
        !capability.limitations.contains("built-without-gnutls-or-schannel") &&
            !capability.limitations.contains("missing-wine-gnutls-runtime")
    }
}

struct SteamClientCompatibilityRegistryRequirement: Hashable {
    var registryPath: String
    var valueName: String
    var valueType: String? = nil
    var valueData: String? = nil
    var expectedValue: String

    var label: String {
        let value = expectedValue.isEmpty ? "<empty>" : expectedValue
        return "\(registryPath)\\\(valueName)=\(value)"
    }
}

struct SteamClientCompatibilityProfileInspection: Hashable {
    var appliedOverrides: [String]
    var missingOverrides: [String]
    var staleOverrides: [String] = []
    var webHelperFiles: SteamClientCompatibilityFileInspection = .empty
    var driverQueryCompatibilityFiles: SteamClientCompatibilityFileInspection = .empty

    var appliedFiles: [String] {
        webHelperFiles.applied + driverQueryCompatibilityFiles.applied
    }

    var missingFiles: [String] {
        webHelperFiles.missing + driverQueryCompatibilityFiles.missing
    }

    var staleFiles: [String] {
        webHelperFiles.stale + driverQueryCompatibilityFiles.stale
    }

    var isSatisfied: Bool {
        missingOverrides.isEmpty &&
            staleOverrides.isEmpty &&
            webHelperFiles.isSatisfied &&
            driverQueryCompatibilityFiles.isSatisfied
    }
}

struct SteamClientCompatibilityFileInspection: Hashable {
    var applied: [String]
    var missing: [String]
    var stale: [String]

    static let empty = SteamClientCompatibilityFileInspection(
        applied: [],
        missing: [],
        stale: []
    )

    var isSatisfied: Bool {
        missing.isEmpty && stale.isEmpty
    }
}

enum SteamClientCompatibilityProfileContract {
    nonisolated static var recommendedVideoMemorySizeMB: Int {
        SteamVideoMemorySelection.automatic.resolvedSizeMB()
    }

    nonisolated static let obsoleteSteamClientRendererIsolationExecutables = [
        "steam.exe",
        "steamwebhelper.exe"
    ]

    nonisolated static let obsoleteSteamClientRendererIsolationDLLs = [
        "libglesv2",
        "d3d8",
        "d3d9",
        "d3d10",
        "d3d10_1",
        "d3d10core",
        "d3d11",
        "dxgi",
        "d3d12",
        "d3d12core",
        "nvapi",
        "nvapi64",
        "nvngx",
        "nvngx-on-metalfx",
        "winemetal"
    ]

    nonisolated static var requiredRegistryOverrides: [SteamClientCompatibilityRegistryRequirement] {
        requiredRegistryOverrides(videoMemorySizeMB: recommendedVideoMemorySizeMB)
    }

    nonisolated static func requiredRegistryOverrides(
        videoMemorySizeMB: Int?
    ) -> [SteamClientCompatibilityRegistryRequirement] {
        let requirements = [
            SteamClientCompatibilityRegistryRequirement(
                registryPath: "HKCU\\Software\\Wine\\Mac Driver",
                valueName: "LeftOptionIsAlt",
                valueData: "Y",
                expectedValue: "Y"
            ),
            SteamClientCompatibilityRegistryRequirement(
                registryPath: "HKCU\\Software\\Wine\\Mac Driver",
                valueName: "RightOptionIsAlt",
                valueData: "Y",
                expectedValue: "Y"
            ),
            SteamClientCompatibilityRegistryRequirement(
                registryPath: "HKCU\\Software\\Wine\\Mac Driver",
                valueName: "LeftCommandIsCtrl",
                valueData: "Y",
                expectedValue: "Y"
            ),
            SteamClientCompatibilityRegistryRequirement(
                registryPath: "HKCU\\Software\\Wine\\Mac Driver",
                valueName: "RightCommandIsCtrl",
                valueData: "Y",
                expectedValue: "Y"
            ),
            SteamClientCompatibilityRegistryRequirement(
                registryPath: "HKCU\\Software\\Wine\\Mac Driver",
                valueName: "UsePreciseScrolling",
                valueData: "N",
                expectedValue: "N"
            ),
            SteamClientCompatibilityRegistryRequirement(
                registryPath: "HKCU\\Software\\Wine\\DllOverrides",
                valueName: "gameoverlayrenderer",
                valueData: "",
                expectedValue: ""
            ),
            SteamClientCompatibilityRegistryRequirement(
                registryPath: "HKCU\\Software\\Wine\\DllOverrides",
                valueName: "*vulkandriverquery.exe",
                valueData: "",
                expectedValue: ""
            ),
            SteamClientCompatibilityRegistryRequirement(
                registryPath: "HKCU\\Software\\Wine\\DllOverrides",
                valueName: "*vulkandriverquery64.exe",
                valueData: "",
                expectedValue: ""
            )
        ]
        guard let videoMemorySizeMB else { return requirements }
        var requirementsWithVideoMemory = requirements
        requirementsWithVideoMemory.insert(
            SteamClientCompatibilityRegistryRequirement(
                registryPath: "HKCU\\Software\\Wine\\Direct3D",
                valueName: "VideoMemorySize",
                valueData: String(videoMemorySizeMB),
                expectedValue: String(videoMemorySizeMB)
            ),
            at: 5
        )
        return requirementsWithVideoMemory
    }

    nonisolated static var obsoleteRegistryOverrides: [SteamClientCompatibilityRegistryRequirement] {
        var requirements: [SteamClientCompatibilityRegistryRequirement] = []
        for appExecutable in obsoleteSteamClientRendererIsolationExecutables {
            for dll in obsoleteSteamClientRendererIsolationDLLs {
                requirements.append(SteamClientCompatibilityRegistryRequirement(
                    registryPath: "HKCU\\Software\\Wine\\AppDefaults\\\(appExecutable)\\DllOverrides",
                    valueName: dll,
                    expectedValue: "<removed>"
                ))
            }
        }
        return requirements
    }

    nonisolated static var requiredSystemRegistryOverrides: [SteamClientCompatibilityRegistryRequirement] {
        [
            SteamClientCompatibilityRegistryRequirement(
                registryPath: "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug",
                valueName: "Auto",
                valueData: "1",
                expectedValue: "1"
            ),
            SteamClientCompatibilityRegistryRequirement(
                registryPath: "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug",
                valueName: "Debugger",
                valueData: "false",
                expectedValue: "false"
            ),
            SteamClientCompatibilityRegistryRequirement(
                registryPath: "HKLM\\System\\CurrentControlSet\\Services\\winebus",
                valueName: "DisableHidraw",
                valueType: "REG_DWORD",
                valueData: "0",
                expectedValue: "dword:00000000"
            ),
            SteamClientCompatibilityRegistryRequirement(
                registryPath: "HKLM\\System\\CurrentControlSet\\Services\\winebus",
                valueName: "DisableInput",
                valueType: "REG_DWORD",
                valueData: "0",
                expectedValue: "dword:00000000"
            ),
            SteamClientCompatibilityRegistryRequirement(
                registryPath: "HKLM\\System\\CurrentControlSet\\Services\\winebus",
                valueName: "Enable SDL",
                valueType: "REG_DWORD",
                valueData: "0",
                expectedValue: "dword:00000000"
            ),
            SteamClientCompatibilityRegistryRequirement(
                registryPath: "HKLM\\System\\CurrentControlSet\\Services\\winebus",
                valueName: "Map Controllers",
                valueType: "REG_DWORD",
                valueData: "0",
                expectedValue: "dword:00000000"
            )
        ]
    }

    nonisolated static let sdl2CompatVersion = "2.32.70"
    private nonisolated static let sdl2CompatRelativeDirectory =
        "Runners/ForgePlayRuntime/SteamCompat/sdl2-compat/2.32.70/win32-x86"
    private nonisolated static let sdl2CompatFileNames = ["SDL2.dll", "SDL3.dll"]
    private nonisolated static let steamWebHelperExecutableName = "steamwebhelper.exe"
    private nonisolated static let legacySteamWebHelperOriginalFileName =
        "steamwebhelper.forgeplay-original.exe"
    private nonisolated static let legacySteamWebHelperOriginalDirectoryName = "forgeplay-original"
    private nonisolated static let steamWebHelperCEFDirectoryNames = [
        "cef.win7x64",
        "cef.win64"
    ]
    nonisolated static let obsoleteSteamBootstrapPinContents = """
    BootStrapperInhibitAll=enable
    BootStrapperForceSelfUpdate=disable

    """

    nonisolated static func inspect(
        prefix: URL,
        fileManager: FileManager = .default,
        videoMemorySizeMB: Int? = nil
    ) -> SteamClientCompatibilityProfileInspection {
        let userRequirements = requiredRegistryOverrides(videoMemorySizeMB: videoMemorySizeMB)
        let systemRequirements = requiredSystemRegistryOverrides
        let obsoleteOverrides = obsoleteRegistryOverrides
        let userRegistry = prefix.appending(path: "user.reg")
        let systemRegistry = prefix.appending(path: "system.reg")
        let fileInspection = inspectRequiredFiles(
            prefix: prefix,
            fileManager: fileManager
        )
        var applied: [String] = []
        var missing: [String] = []
        var stale: [String] = []

        if FileSystemItemPolicy.isRegularNonSymlinkFile(userRegistry, fileManager: fileManager),
           let userContents = try? String(contentsOf: userRegistry, encoding: .utf8) {
            let userSnapshot = WineUserRegistrySnapshot(contents: userContents)
            for requirement in userRequirements {
                if userSnapshot.value(
                    forRegistryPath: requirement.registryPath,
                    valueName: requirement.valueName
                ) == requirement.expectedValue {
                    applied.append(requirement.label)
                } else {
                    missing.append(requirement.label)
                }
            }
            for obsoleteOverride in obsoleteOverrides {
                if userSnapshot.value(
                    forRegistryPath: obsoleteOverride.registryPath,
                    valueName: obsoleteOverride.valueName
                ) != nil {
                    stale.append(obsoleteOverride.label)
                }
            }
        } else {
            missing.append(contentsOf: userRequirements.map(\.label))
        }

        if FileSystemItemPolicy.isRegularNonSymlinkFile(systemRegistry, fileManager: fileManager),
           let systemContents = try? String(contentsOf: systemRegistry, encoding: .utf8) {
            let systemSnapshot = WineUserRegistrySnapshot(contents: systemContents)
            for requirement in systemRequirements {
                if systemSnapshot.value(
                    forRegistryPath: requirement.registryPath,
                    valueName: requirement.valueName
                ) == requirement.expectedValue {
                    applied.append(requirement.label)
                } else {
                    missing.append(requirement.label)
                }
            }
        } else {
            missing.append(contentsOf: systemRequirements.map(\.label))
        }
        return SteamClientCompatibilityProfileInspection(
            appliedOverrides: applied,
            missingOverrides: missing,
            staleOverrides: stale,
            webHelperFiles: fileInspection.webHelper,
            driverQueryCompatibilityFiles: fileInspection.driverQueryCompatibility
        )
    }

    nonisolated static func configuredVideoMemorySizeMB(
        in prefix: URL,
        fileManager: FileManager = .default
    ) -> Int? {
        let userRegistry = prefix.appending(path: "user.reg")
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(userRegistry, fileManager: fileManager),
              let contents = try? String(contentsOf: userRegistry, encoding: .utf8),
              let value = WineUserRegistrySnapshot(contents: contents).value(
                forRegistryPath: "HKCU\\Software\\Wine\\Direct3D",
                valueName: "VideoMemorySize"
              ),
              let sizeMB = Int(value),
              sizeMB > 0 else {
            return nil
        }
        return sizeMB
    }

    nonisolated static func sdl2CompatResourceDirectory(fileManager: FileManager = .default) -> URL? {
        let bundleCandidates = [
            Bundle.main.resourceURL,
            Bundle(for: ForgePlayBundleToken.self).resourceURL
        ]
        var resourceCandidates = bundleCandidates.compactMap { resourceURL in
            resourceURL?.appending(path: sdl2CompatRelativeDirectory, directoryHint: .isDirectory)
        }
        #if DEBUG
        let sourceFile = URL(fileURLWithPath: #filePath)
        let sourceRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceCandidate = sourceRoot.appending(
            path: "Resources/\(sdl2CompatRelativeDirectory)",
            directoryHint: .isDirectory
        )
        resourceCandidates.append(sourceCandidate)
        #endif
        return resourceCandidates.first { candidate in
            FileSystemItemPolicy.isNonSymlinkDirectory(candidate, fileManager: fileManager) &&
                sdl2CompatFileNames.allSatisfy { fileName in
                    FileSystemItemPolicy.isRegularNonSymlinkFile(
                        candidate.appending(path: fileName),
                        fileManager: fileManager
                    )
                }
        }
    }

    nonisolated static func steamDirectory(in prefix: URL) -> URL {
        prefix.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
    }

    nonisolated static func steamBinDirectory(in prefix: URL) -> URL {
        steamDirectory(in: prefix).appending(path: "bin", directoryHint: .isDirectory)
    }

    nonisolated static func steamWebHelperCandidateDirectories(in prefix: URL) -> [URL] {
        let cefRoot = steamBinDirectory(in: prefix).appending(path: "cef", directoryHint: .isDirectory)
        return steamWebHelperCEFDirectoryNames.map {
            cefRoot.appending(path: $0, directoryHint: .isDirectory)
        }
    }

    nonisolated static func steamWebHelperFile(in cefDirectory: URL) -> URL {
        cefDirectory.appending(path: steamWebHelperExecutableName)
    }

    nonisolated static func steamWebHelperOriginalFile(in cefDirectory: URL) -> URL {
        cefDirectory.appending(path: legacySteamWebHelperOriginalFileName)
    }

    nonisolated static func legacySteamWebHelperOriginalFile(in cefDirectory: URL) -> URL {
        cefDirectory
            .appending(path: legacySteamWebHelperOriginalDirectoryName, directoryHint: .isDirectory)
            .appending(path: steamWebHelperExecutableName)
    }

    private nonisolated static func inspectRequiredFiles(
        prefix: URL,
        fileManager: FileManager
    ) -> (
        webHelper: SteamClientCompatibilityFileInspection,
        driverQueryCompatibility: SteamClientCompatibilityFileInspection
    ) {
        let webHelper = inspectSteamWebHelperFiles(prefix: prefix, fileManager: fileManager)
        let sdl2Compat = inspectSDL2CompatFiles(prefix: prefix, fileManager: fileManager)
        return (
            SteamClientCompatibilityFileInspection(
                applied: webHelper.applied,
                missing: webHelper.missing,
                stale: webHelper.stale
            ),
            SteamClientCompatibilityFileInspection(
                applied: sdl2Compat.applied,
                missing: sdl2Compat.missing,
                stale: sdl2Compat.stale
            )
        )
    }

    nonisolated static func hasSteamClientPayload(
        in prefix: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let steamDirectory = steamDirectory(in: prefix)
        let webHelperCandidates = [
            steamDirectory.appending(path: "bin/cef/cef.win64/steamwebhelper.exe"),
            steamDirectory.appending(path: "bin/cef/cef.win7x64/steamwebhelper.exe"),
            steamDirectory.appending(path: "bin/cef/cef.win32/steamwebhelper.exe")
        ]
        return webHelperCandidates.contains {
            FileSystemItemPolicy.isRegularNonSymlinkFile($0, fileManager: fileManager)
        }
    }

    private nonisolated static func inspectSteamWebHelperFiles(
        prefix: URL,
        fileManager: FileManager
    ) -> (applied: [String], missing: [String], stale: [String]) {
        let cefDirectories = steamWebHelperCandidateDirectories(in: prefix).filter {
            FileSystemItemPolicy.isNonSymlinkDirectory($0, fileManager: fileManager)
        }
        guard !cefDirectories.isEmpty else {
            return ([], [], [])
        }
        var applied: [String] = []
        var missing: [String] = []
        var stale: [String] = []
        for cefDirectory in cefDirectories {
            let current = steamWebHelperFile(in: cefDirectory)
            let original = steamWebHelperOriginalFile(in: cefDirectory)
            let legacyOriginal = legacySteamWebHelperOriginalFile(in: cefDirectory)
            let relativeRoot = "Steam/bin/cef/\(cefDirectory.lastPathComponent)"
            let activeOriginalLabel = "\(relativeRoot)/steamwebhelper.exe=valve-managed"
            let preservedOriginalLabel =
                "\(relativeRoot)/\(legacySteamWebHelperOriginalFileName)=obsolete-preserved-original"
            let legacyLabel =
                "\(relativeRoot)/forgeplay-original/steamwebhelper.exe=legacy-original-location"

            guard FileSystemItemPolicy.isRegularNonSymlinkFile(current, fileManager: fileManager) ||
                    FileSystemItemPolicy.isRegularNonSymlinkFile(original, fileManager: fileManager) ||
                    FileSystemItemPolicy.isRegularNonSymlinkFile(legacyOriginal, fileManager: fileManager) else {
                continue
            }

            if FileSystemItemPolicy.isRegularNonSymlinkFile(current, fileManager: fileManager) {
                if isKnownForgePlaySteamWebHelperShim(current, fileManager: fileManager) {
                    stale.append("\(relativeRoot)/steamwebhelper.exe=obsolete-forgeplay-shim")
                    missing.append(activeOriginalLabel)
                } else {
                    applied.append(activeOriginalLabel)
                }
            } else {
                missing.append(activeOriginalLabel)
            }

            if FileSystemItemPolicy.isRegularNonSymlinkFile(original, fileManager: fileManager) {
                stale.append(preservedOriginalLabel)
            }

            if FileSystemItemPolicy.isRegularNonSymlinkFile(legacyOriginal, fileManager: fileManager) {
                stale.append(legacyLabel)
            }
        }
        return (applied, missing, stale)
    }

    nonisolated static func isKnownForgePlaySteamWebHelperShim(
        _ file: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(file, fileManager: fileManager),
              let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value > 0,
              size.uint64Value < 1_000_000,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            return false
        }
        return data.range(of: Data("steamwebhelper-shim.c".utf8)) != nil
    }

    private nonisolated static func inspectSDL2CompatFiles(
        prefix: URL,
        fileManager: FileManager
    ) -> (applied: [String], missing: [String], stale: [String]) {
        let steamBin = steamBinDirectory(in: prefix)
        let driverQuery = steamBin.appending(path: "gldriverquery.exe")
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(driverQuery, fileManager: fileManager) else {
            return ([], [], [])
        }
        guard let resourceDirectory = sdl2CompatResourceDirectory(fileManager: fileManager) else {
            return (
                [],
                ["bundled sdl2-compat \(sdl2CompatVersion) win32-x86 payload"],
                []
            )
        }

        var applied: [String] = []
        var missing: [String] = []
        var stale: [String] = []
        for fileName in sdl2CompatFileNames {
            let source = resourceDirectory.appending(path: fileName)
            let destination = steamBin.appending(path: fileName)
            let label = "Steam/bin/\(fileName)=sdl2-compat-\(sdl2CompatVersion)-win32-x86"
            guard FileSystemItemPolicy.isRegularNonSymlinkFile(destination, fileManager: fileManager) else {
                missing.append(label)
                continue
            }
            if fileManager.contentsEqual(atPath: source.path, andPath: destination.path) {
                applied.append(label)
            } else {
                stale.append(label)
            }
        }
        return (applied, missing, stale)
    }
}

private final class ForgePlayBundleToken: NSObject {}

struct WineUserRegistrySnapshot {
    private var valuesBySection: [String: [String: String]] = [:]

    init(contents: String) {
        var currentSection: String?
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") else { continue }
            if line.hasPrefix("["), let closing = line.firstIndex(of: "]") {
                let sectionText = String(line[line.index(after: line.startIndex)..<closing])
                currentSection = Self.normalizedRegistryPath(sectionText)
                continue
            }
            guard let currentSection,
                  line.hasPrefix("\""),
                  let separator = line.firstIndex(of: "=") else { continue }
            let rawName = String(line[..<separator])
            let rawValue = String(line[line.index(after: separator)...])
            let name = Self.unquotedRegistryToken(rawName)
            let value = Self.unquotedRegistryToken(rawValue)
            valuesBySection[currentSection, default: [:]][name.lowercased()] = value
        }
    }

    func value(forRegistryPath registryPath: String, valueName: String) -> String? {
        valuesBySection[Self.normalizedRegistryPath(registryPath)]?[valueName.lowercased()]
    }

    func multiStringValues(forRegistryPath registryPath: String, valueName: String) -> [String]? {
        guard let rawValue = value(
            forRegistryPath: registryPath,
            valueName: valueName
        ) else {
            return nil
        }
        let prefix = "str(7):\""
        guard rawValue.hasPrefix(prefix), rawValue.hasSuffix("\"") else { return nil }
        let payloadStart = rawValue.index(rawValue.startIndex, offsetBy: prefix.count)
        let payloadEnd = rawValue.index(before: rawValue.endIndex)
        return rawValue[payloadStart..<payloadEnd]
            .components(separatedBy: "\\0")
            .filter { !$0.isEmpty }
    }

    private static func normalizedRegistryPath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.lowercased().hasPrefix("hkcu\\") {
            normalized.removeFirst("HKCU\\".count)
        } else if normalized.lowercased().hasPrefix("hklm\\") {
            normalized.removeFirst("HKLM\\".count)
        }
        while normalized.contains("\\\\") {
            normalized = normalized.replacingOccurrences(of: "\\\\", with: "\\")
        }
        let currentControlSetPrefix = "system\\currentcontrolset\\"
        if normalized.lowercased().hasPrefix(currentControlSetPrefix) {
            let suffix = normalized.dropFirst(currentControlSetPrefix.count)
            normalized = "System\\ControlSet001\\\(suffix)"
        }
        return normalized.lowercased()
    }

    private static func unquotedRegistryToken(_ token: String) -> String {
        var trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        return trimmed
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }
}

@MainActor
final class SteamClientCompatibilityProfile {
    nonisolated static let defaultLaunchArguments = baseLaunchArguments

    nonisolated static func launchArguments(for rendererPolicy: SteamRendererPolicyPreference) -> [String] {
        switch rendererPolicy {
        case .d3dMetal, .dxmt, .d9vk, .vulkan:
            return baseLaunchArguments
        }
    }

    nonisolated static let cefSandboxMitigationArguments = [
        "-no-cef-sandbox"
    ]

    private nonisolated static let baseLaunchArguments = cefSandboxMitigationArguments

    private let runner: SafeProcessRunner
    private let fileManager: FileManager

    init(runner: SafeProcessRunner, fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    func apply(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        videoMemorySizeMB: Int = SteamClientCompatibilityProfileContract.recommendedVideoMemorySizeMB
    ) async throws -> ProcessRunResult? {
        try removeObsoleteSteamBootstrapPin(prefix: prefix)
        try removeObsoleteSteamCompatibilityBackups(prefix: prefix)
        let initialInspection = SteamClientCompatibilityProfileContract.inspect(
            prefix: prefix,
            fileManager: fileManager,
            videoMemorySizeMB: videoMemorySizeMB
        )
        guard !initialInspection.isSatisfied else { return nil }

        try restoreValveManagedSteamWebHelperIfNeeded(prefix: prefix)
        try installSDL2CompatForSteamGPUQueryIfNeeded(prefix: prefix)
        let actions = overrideActions(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory,
            inspection: initialInspection,
            videoMemorySizeMB: videoMemorySizeMB
        )
        for action in actions {
            let result = try await runner.run(action)
            guard result.succeeded else { return result }
        }
        guard !actions.isEmpty else { return nil }

        // Registry writes are committed when the short-lived Wine session
        // exits naturally. A forced prefix shutdown can terminate wineserver
        // before user.reg/system.reg have been persisted.
        let registryFlush = try await runner.run(.waitForWinePrefix(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory
        ))
        guard registryFlush.succeeded else { return registryFlush }
        return nil
    }

    private func overrideActions(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        inspection: SteamClientCompatibilityProfileInspection,
        videoMemorySizeMB: Int
    ) -> [RunnerAction] {
        let missingOverrides = Set(inspection.missingOverrides)
        let staleOverrides = Set(inspection.staleOverrides)
        let requiredRegistryOverrides = SteamClientCompatibilityProfileContract.requiredRegistryOverrides(
            videoMemorySizeMB: videoMemorySizeMB
        )
        var actions = registryDefaultActions(
            runtimeExecutable: runtimeExecutable,
            prefix: prefix,
            logDirectory: logDirectory,
            missingOverrides: missingOverrides,
            requiredRegistryOverrides: requiredRegistryOverrides
        )

        let requiredDLLOverrides = requiredRegistryOverrides.filter {
            $0.registryPath == "HKCU\\Software\\Wine\\DllOverrides" && missingOverrides.contains($0.label)
        }
        for requirement in requiredDLLOverrides {
            actions.append(.setDLLOverride(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                dll: requirement.valueName,
                override: requirement.valueData ?? requirement.expectedValue,
                logDirectory: logDirectory
            ))
        }

        for appExecutable in SteamClientCompatibilityProfileContract.obsoleteSteamClientRendererIsolationExecutables {
            for dll in SteamClientCompatibilityProfileContract.obsoleteSteamClientRendererIsolationDLLs {
                let requirement = SteamClientCompatibilityRegistryRequirement(
                    registryPath: "HKCU\\Software\\Wine\\AppDefaults\\\(appExecutable)\\DllOverrides",
                    valueName: dll,
                    expectedValue: "<removed>"
                )
                guard staleOverrides.contains(requirement.label) else { continue }
                actions.append(.deleteAppDLLOverrideIfPresent(
                    runtimeExecutable: runtimeExecutable,
                    prefix: prefix,
                    appExecutable: appExecutable,
                    dll: dll,
                    logDirectory: logDirectory
                ))
            }
        }

        return actions
    }

    private func registryDefaultActions(
        runtimeExecutable: URL,
        prefix: URL,
        logDirectory: URL,
        missingOverrides: Set<String>,
        requiredRegistryOverrides: [SteamClientCompatibilityRegistryRequirement]
    ) -> [RunnerAction] {
        let requirements = requiredRegistryOverrides
            .filter {
                $0.registryPath == "HKCU\\Software\\Wine\\Mac Driver" ||
                    $0.registryPath == "HKCU\\Software\\Wine\\Direct3D"
            } +
            SteamClientCompatibilityProfileContract.requiredSystemRegistryOverrides
        return requirements.filter { missingOverrides.contains($0.label) }.map { requirement in
            .setRegistryValue(
                runtimeExecutable: runtimeExecutable,
                prefix: prefix,
                registryPath: requirement.registryPath,
                valueName: requirement.valueName,
                valueType: requirement.valueType,
                value: requirement.valueData ?? requirement.expectedValue,
                logDirectory: logDirectory
            )
        }
    }

    private func removeObsoleteSteamBootstrapPin(prefix: URL) throws {
        let steamDirectory = SteamClientCompatibilityProfileContract.steamDirectory(in: prefix)
        guard FileSystemItemPolicy.isNonSymlinkDirectory(steamDirectory, fileManager: fileManager) else {
            return
        }
        let steamConfig = steamDirectory.appending(path: "steam.cfg")
        do {
            guard FileSystemItemPolicy.isRegularNonSymlinkFile(steamConfig, fileManager: fileManager) else {
                return
            }
            if try String(contentsOf: steamConfig, encoding: .utf8) ==
                SteamClientCompatibilityProfileContract.obsoleteSteamBootstrapPinContents {
                try fileManager.removeItem(at: steamConfig)
            }
        } catch {
            throw SteamLaunchError.steamClientCompatibilityFileInstallFailed(
                steamConfig,
                forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    private func restoreValveManagedSteamWebHelperIfNeeded(prefix: URL) throws {
        let cefDirectories = SteamClientCompatibilityProfileContract
            .steamWebHelperCandidateDirectories(in: prefix)
            .filter {
                FileSystemItemPolicy.isNonSymlinkDirectory($0, fileManager: fileManager)
            }
        guard !cefDirectories.isEmpty else { return }

        for cefDirectory in cefDirectories {
            let current = SteamClientCompatibilityProfileContract.steamWebHelperFile(in: cefDirectory)
            let preserved = SteamClientCompatibilityProfileContract.steamWebHelperOriginalFile(in: cefDirectory)
            let legacy = SteamClientCompatibilityProfileContract.legacySteamWebHelperOriginalFile(in: cefDirectory)
            do {
                let currentIsShim = SteamClientCompatibilityProfileContract
                    .isKnownForgePlaySteamWebHelperShim(current, fileManager: fileManager)
                if currentIsShim || !FileSystemItemPolicy.isRegularNonSymlinkFile(current, fileManager: fileManager) {
                    let replacement = [preserved, legacy].first {
                        FileSystemItemPolicy.isRegularNonSymlinkFile($0, fileManager: fileManager)
                    }
                    guard let replacement else {
                        throw FileSystemItemPolicyError.notRegularNonSymlinkFile(current)
                    }
                    if fileManager.fileExists(atPath: current.path) {
                        try FileSystemItemPolicy.requireRegularNonSymlinkFile(current, fileManager: fileManager)
                        try fileManager.removeItem(at: current)
                    }
                    try fileManager.moveItem(at: replacement, to: current)
                }

                for obsolete in [preserved, legacy] where fileManager.fileExists(atPath: obsolete.path) {
                    try FileSystemItemPolicy.requireRegularNonSymlinkFile(obsolete, fileManager: fileManager)
                    try fileManager.removeItem(at: obsolete)
                }
                try removeEmptySteamWebHelperOriginalDirectoryIfNeeded(legacy.deletingLastPathComponent())
            } catch {
                throw SteamLaunchError.steamClientCompatibilityFileInstallFailed(
                    current,
                    forgePlayTechnicalErrorSummary(error)
                )
            }
        }
        try removeObsoleteSteamCompatibilityBackups(prefix: prefix)
    }

    private func removeObsoleteSteamCompatibilityBackups(prefix: URL) throws {
        let backups = prefix.appending(
            path: "drive_c/ForgePlay/SteamCompatBackups",
            directoryHint: .isDirectory
        )
        guard fileManager.fileExists(atPath: backups.path) else { return }
        guard FileSystemItemPolicy.isNonSymlinkDirectory(backups, fileManager: fileManager) else {
            throw FileSystemItemPolicyError.notNonSymlinkDirectory(backups)
        }
        try fileManager.removeItem(at: backups)
    }

    private func removeEmptySteamWebHelperOriginalDirectoryIfNeeded(_ directory: URL) throws {
        guard FileSystemItemPolicy.isNonSymlinkDirectory(directory, fileManager: fileManager) else {
            return
        }
        if (try fileManager.contentsOfDirectory(atPath: directory.path)).isEmpty {
            try fileManager.removeItem(at: directory)
        }
    }

    private func installSDL2CompatForSteamGPUQueryIfNeeded(prefix: URL) throws {
        let steamBin = SteamClientCompatibilityProfileContract.steamBinDirectory(in: prefix)
        let driverQuery = steamBin.appending(path: "gldriverquery.exe")
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(driverQuery, fileManager: fileManager) else {
            return
        }
        guard let sourceDirectory = SteamClientCompatibilityProfileContract.sdl2CompatResourceDirectory(
            fileManager: fileManager
        ) else {
            throw SteamLaunchError.steamClientCompatibilityFileInstallFailed(
                driverQuery,
                "bundled sdl2-compat \(SteamClientCompatibilityProfileContract.sdl2CompatVersion) win32-x86 payload is missing"
            )
        }
        guard FileSystemItemPolicy.isNonSymlinkDirectory(steamBin, fileManager: fileManager) else {
            throw SteamLaunchError.steamClientCompatibilityFileInstallFailed(
                steamBin,
                "Steam bin directory is missing or unsafe"
            )
        }

        for fileName in ["SDL2.dll", "SDL3.dll"] {
            let source = sourceDirectory.appending(path: fileName)
            let destination = steamBin.appending(path: fileName)
            do {
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(source, fileManager: fileManager)
                if FileSystemItemPolicy.isRegularNonSymlinkFile(destination, fileManager: fileManager),
                   fileManager.contentsEqual(atPath: source.path, andPath: destination.path) {
                    continue
                }
                if fileManager.fileExists(atPath: destination.path) {
                    try FileSystemItemPolicy.requireRegularNonSymlinkFile(destination, fileManager: fileManager)
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                throw SteamLaunchError.steamClientCompatibilityFileInstallFailed(
                    destination,
                    forgePlayTechnicalErrorSummary(error)
                )
            }
        }
    }
}
