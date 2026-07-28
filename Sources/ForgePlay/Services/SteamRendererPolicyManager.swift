import Darwin
import Foundation

final class SteamRendererPolicyManager {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func resolvedPolicy(
        _ requestedRendererPolicy: SteamRendererPolicyPreference?,
        capability: WindowsRuntimeCapability
    ) throws -> SteamRendererPolicyPreference {
        if let requestedRendererPolicy {
            guard requestedRendererPolicy.isSatisfied(by: capability) else {
                throw SteamLaunchError.rendererPolicyUnavailable(
                    "선택한 게임 렌더러 payload(\(requestedRendererPolicy.labelKey))는 현재 실행 엔진에서 사용할 수 없습니다."
                )
            }
            return requestedRendererPolicy
        }
        throw SteamLaunchError.rendererPolicyUnavailable(
            "Steam을 실행하기 전에 D3DMetal, DXMT, D9VK 또는 DXVK 중 하나를 직접 선택해야 합니다."
        )
    }

    static func selection(for policy: SteamRendererPolicyPreference) -> SteamRendererPolicySelection {
        switch policy {
        case .d3dMetal:
            .d3dMetal
        case .dxmt:
            .dxmt
        case .d9vk:
            .d9vk
        case .vulkan:
            .vulkan
        }
    }

    func inspect(
        prefix: URL,
        runtimeExecutable: URL,
        selection: SteamRendererPolicySelection,
        videoMemorySizeMB: Int? = nil
    ) -> SteamRendererPolicyInspection {
        let capability = WindowsRuntimeService.inspectRuntimeCapability(
            for: runtimeExecutable,
            supplementalRendererRoot: ForgePlaySupplementalRendererPolicy.rendererRoot(containingPrefix: prefix),
            fileManager: fileManager
        )
        let steamClientVerification = SteamClientCompatibilityVerifier.verify(capability: capability)
        guard steamClientVerification.canLaunchWindowsSteam else {
            return SteamRendererPolicyInspection(
                selection: selection,
                resolvedPolicy: selection.resolvedLaunchPreference(capability: capability),
                status: .error,
                userMessage: steamClientVerification.userMessage,
                appliedModules: [],
                missingModules: [],
                mixedModules: [],
                recoveryKind: .runtimeUnavailable
            )
        }
        guard let resolvedPolicy = selection.resolvedLaunchPreference(capability: capability) else {
            return SteamRendererPolicyInspection(
                selection: selection,
                resolvedPolicy: nil,
                status: .error,
                userMessage: capability.userMessage,
                appliedModules: [],
                missingModules: [],
                mixedModules: [],
                recoveryKind: .runtimeUnavailable
            )
        }
        guard FileSystemItemPolicy.isNonSymlinkDirectory(prefix, fileManager: fileManager) else {
            return SteamRendererPolicyInspection(
                selection: selection,
                resolvedPolicy: resolvedPolicy,
                status: .warning,
                userMessage: "Steam 프리픽스를 먼저 만들어야 Steam 실행 경로를 정비할 수 있습니다.",
                appliedModules: [],
                missingModules: [],
                mixedModules: []
            )
        }

        do {
            let selectedModules = try SafeProcessRunner.rendererWindowsModuleFilesByWindowsDirectory(
                for: runtimeExecutable,
                graphicsBackend: resolvedPolicy,
                prefix: prefix
            )
            let allKnownModules = try knownRendererBridgeModulesByWindowsDirectory(
                for: runtimeExecutable,
                prefix: prefix
            )
            guard selectedModules.values.contains(where: { !$0.isEmpty }) else {
                return SteamRendererPolicyInspection(
                    selection: selection,
                    resolvedPolicy: resolvedPolicy,
                    status: .error,
                    userMessage: "선택한 게임 렌더러 payload에 필요한 renderer DLL을 실행 엔진에서 찾지 못했습니다.",
                    appliedModules: [],
                    missingModules: [],
                    mixedModules: []
                )
            }
            _ = try SafeProcessRunner.steamGameRendererPolicyEnvironment(
                for: runtimeExecutable,
                prefix: prefix,
                graphicsBackend: resolvedPolicy,
                logDirectory: prefix
            )

            var contaminatingModules: [String] = []
            let existingWindowsDirectoryNames = Self.rendererPolicyWindowsDirectoryNames.filter { directoryName in
                fileManager.fileExists(
                    atPath: prefix.appending(path: "drive_c/windows/\(directoryName)", directoryHint: .isDirectory).path
                )
            }
            let directoryNamesToInspect = Set(selectedModules.keys)
                .union(allKnownModules.keys)
                .union(existingWindowsDirectoryNames)
            for windowsDirectoryName in directoryNamesToInspect.sorted() {
                let windowsDirectory = prefix.appending(path: "drive_c/windows/\(windowsDirectoryName)", directoryHint: .isDirectory)
                if !fileManager.fileExists(atPath: windowsDirectory.path) {
                    continue
                }
                guard FileSystemItemPolicy.isNonSymlinkDirectory(windowsDirectory, fileManager: fileManager) else {
                    contaminatingModules.append("\(windowsDirectoryName): directory unavailable")
                    continue
                }

                for moduleName in Self.rendererPolicyDLLNames {
                    let destination = windowsDirectory.appending(path: moduleName)
                    guard FileSystemItemPolicy.isRegularNonSymlinkFile(destination, fileManager: fileManager) else {
                        continue
                    }
                    if isKnownRendererModule(
                        destination,
                        knownRendererModules: allKnownModules[windowsDirectoryName, default: []]
                    ) || Self.hasRendererBridgeMarker(destination, fileManager: fileManager) {
                        contaminatingModules.append("\(windowsDirectoryName)/\(moduleName)")
                    }
                }
            }

            if !contaminatingModules.isEmpty {
                let profileInspection = SteamClientCompatibilityProfileContract.inspect(
                    prefix: prefix,
                    fileManager: fileManager,
                    videoMemorySizeMB: videoMemorySizeMB
                )
                return SteamRendererPolicyInspection(
                    selection: selection,
                    resolvedPolicy: resolvedPolicy,
                    status: .error,
                    userMessage: "Steam 프리픽스에 Windows용 Steam 클라이언트가 직접 로드할 수 있는 renderer DLL overlay가 남아 있습니다. Steam UI는 기본 Wine 경로로 실행해야 하므로 Steam 실행 전에 실행 경로 정비/검증으로 overlay를 복구해야 합니다.",
                    appliedModules: [],
                    missingModules: [],
                    mixedModules: contaminatingModules,
                    appliedProfileOverrides: profileInspection.appliedOverrides,
                    missingProfileOverrides: profileInspection.missingOverrides,
                    staleProfileOverrides: profileInspection.staleOverrides,
                    appliedSteamClientFiles: profileInspection.appliedFiles,
                    missingSteamClientFiles: profileInspection.missingFiles,
                    staleSteamClientFiles: profileInspection.staleFiles
                )
            }
            let profileInspection = SteamClientCompatibilityProfileContract.inspect(
                prefix: prefix,
                fileManager: fileManager,
                videoMemorySizeMB: videoMemorySizeMB
            )
            if !profileInspection.isSatisfied {
                let requiresExplicitFileRepair = !profileInspection.staleFiles.isEmpty
                let message: String
                if !profileInspection.staleOverrides.isEmpty {
                    message = "Steam 클라이언트에 오래된 renderer 강제 override가 남아 있습니다. Steam 실행 전에 ForgePlay가 프로필을 정비해야 합니다."
                } else if !profileInspection.staleFiles.isEmpty {
                    message = "Steam 클라이언트 보조 구성요소가 현재 앱 버전과 맞지 않습니다. Steam 실행 전에 ForgePlay가 실행 경로를 복구해야 합니다."
                } else if !profileInspection.missingFiles.isEmpty {
                    message = "Steam 클라이언트 보조 구성요소가 아직 준비되지 않았습니다. Steam 실행 전에 ForgePlay가 실행 경로를 준비해야 합니다."
                } else {
                    message = "Steam 클라이언트 호환성 프로필이 Steam 프리픽스에 아직 적용되지 않았습니다. Steam 실행 전에 ForgePlay가 프로필을 적용해야 합니다."
                }
                return SteamRendererPolicyInspection(
                    selection: selection,
                    resolvedPolicy: resolvedPolicy,
                    status: requiresExplicitFileRepair ? .error : .warning,
                    userMessage: message,
                    appliedModules: [],
                    missingModules: [],
                    mixedModules: [],
                    appliedProfileOverrides: profileInspection.appliedOverrides,
                    missingProfileOverrides: profileInspection.missingOverrides,
                    staleProfileOverrides: profileInspection.staleOverrides,
                    appliedSteamClientFiles: profileInspection.appliedFiles,
                    missingSteamClientFiles: profileInspection.missingFiles,
                    staleSteamClientFiles: profileInspection.staleFiles,
                    recoveryKind: requiresExplicitFileRepair ? .repairPolicy : .applyPolicy
                )
            }
            return SteamRendererPolicyInspection(
                selection: selection,
                resolvedPolicy: resolvedPolicy,
                status: .ok,
                userMessage: "Steam UI는 기본 Wine 경로로 유지되고, 선택한 단일 백엔드를 Steam 게임 실행 계보에 적용할 준비가 되어 있습니다.",
                appliedModules: [],
                missingModules: [],
                mixedModules: [],
                appliedProfileOverrides: profileInspection.appliedOverrides,
                missingProfileOverrides: [],
                staleProfileOverrides: [],
                appliedSteamClientFiles: profileInspection.appliedFiles,
                missingSteamClientFiles: [],
                staleSteamClientFiles: []
            )
        } catch {
            return SteamRendererPolicyInspection(
                selection: selection,
                resolvedPolicy: resolvedPolicy,
                status: .error,
                userMessage: "Steam 실행 경로와 게임 렌더러 payload 상태를 확인하지 못했습니다: \(forgePlayTechnicalErrorSummary(error))",
                appliedModules: [],
                missingModules: [],
                mixedModules: []
            )
        }
    }

    func restoreBridgeModules(
        prefix: URL,
        runtimeExecutable: URL
    ) throws {
        try requireContainedNonSymlinkDirectory(prefix, within: prefix)
        let allKnownModulesByWindowsDirectory = try knownRendererBridgeModulesByWindowsDirectory(
            for: runtimeExecutable,
            prefix: prefix
        )
        for directoryName in Self.rendererPolicyWindowsDirectoryNames {
            let windowsDirectory = prefix.appending(path: "drive_c/windows/\(directoryName)", directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: windowsDirectory.path) else {
                continue
            }
            do {
                try requireContainedNonSymlinkDirectory(windowsDirectory, within: prefix)
            } catch {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    windowsDirectory,
                    "\(directoryName) folder is outside the safe prefix directory boundary: \(forgePlayTechnicalErrorSummary(error))"
                )
            }
            let backupDirectory = prefix.appending(
                path: "drive_c/ForgePlay/RendererBackups/\(directoryName)",
                directoryHint: .isDirectory
            )
            do {
                try createContainedNonSymlinkDirectoryIfNeeded(backupDirectory, within: prefix)
                try restoreUnselectedBridgeModules(
                    in: windowsDirectory,
                    backupDirectory: backupDirectory,
                    selectedModuleNames: []
                )
                try removeUnbackedBridgeModules(
                    in: windowsDirectory,
                    backupDirectory: backupDirectory,
                    knownRendererModules: allKnownModulesByWindowsDirectory[directoryName, default: []]
                )
            } catch {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    backupDirectory,
                    forgePlayTechnicalErrorSummary(error)
                )
            }
        }
    }

    private func restoreUnselectedBridgeModules(
        in system32: URL,
        backupDirectory: URL,
        selectedModuleNames: Set<String>
    ) throws {
        for moduleName in SafeProcessRunner.rendererBridgeDLLNames.subtracting(selectedModuleNames) {
            let destination = system32.appending(path: moduleName)
            let backup = backupDirectory.appending(path: "\(moduleName).original")
            guard fileManager.fileExists(atPath: backup.path) else { continue }
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(backup, fileManager: fileManager)

            if fileManager.fileExists(atPath: destination.path) {
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(destination, fileManager: fileManager)
                if fileManager.contentsEqual(atPath: destination.path, andPath: backup.path) {
                    continue
                }
            }

            try restoreRegularFileAtomically(from: backup, to: destination)
        }
    }

    private func restoreRegularFileAtomically(from backup: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appending(
            path: ".\(destination.lastPathComponent).restore-\(UUID().uuidString)"
        )
        defer {
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
        }

        try fileManager.copyItem(at: backup, to: temporary)
        try FileSystemItemPolicy.requireRegularNonSymlinkFile(temporary, fileManager: fileManager)

        if fileManager.fileExists(atPath: destination.path) {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(destination, fileManager: fileManager)
            try swapFilesAtomically(temporary, destination)
            do {
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(destination, fileManager: fileManager)
            } catch {
                do {
                    try swapFilesAtomically(temporary, destination)
                } catch let rollbackError {
                    throw SteamLaunchError.rendererBridgeInstallFailed(
                        destination,
                        "restored renderer validation failed and the original could not be rolled back: \(forgePlayTechnicalErrorSummary(error)); rollback: \(forgePlayTechnicalErrorSummary(rollbackError))"
                    )
                }
                throw error
            }
            try fileManager.removeItem(at: temporary)
        } else {
            try renameFileAtomically(temporary, destination)
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(destination, fileManager: fileManager)
        }
    }

    private func requireContainedNonSymlinkDirectory(_ directory: URL, within prefix: URL) throws {
        let prefix = prefix.standardizedFileURL
        let directory = directory.standardizedFileURL
        if directory.path == prefix.path {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(directory, fileManager: fileManager)
            return
        }
        guard directory.path.hasPrefix("\(prefix.path)/"),
              FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                from: prefix,
                to: directory,
                fileManager: fileManager
              ),
              FileSystemItemPolicy.isNonSymlinkDirectory(directory, fileManager: fileManager) else {
            throw FileSystemItemPolicyError.notNonSymlinkDirectory(directory)
        }
    }

    private func createContainedNonSymlinkDirectoryIfNeeded(_ directory: URL, within prefix: URL) throws {
        let prefix = prefix.standardizedFileURL
        let directory = directory.standardizedFileURL
        guard directory.path == prefix.path || directory.path.hasPrefix("\(prefix.path)/") else {
            throw FileSystemItemPolicyError.notNonSymlinkDirectory(directory)
        }
        if directory.path == prefix.path {
            try requireContainedNonSymlinkDirectory(directory, within: prefix)
            return
        }

        let parent = directory.deletingLastPathComponent()
        try createContainedNonSymlinkDirectoryIfNeeded(parent, within: prefix)
        if fileManager.fileExists(atPath: directory.path) {
            try requireContainedNonSymlinkDirectory(directory, within: prefix)
            return
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try requireContainedNonSymlinkDirectory(directory, within: prefix)
    }

    private func swapFilesAtomically(_ first: URL, _ second: URL) throws {
        let result: Int32 = first.withUnsafeFileSystemRepresentation { firstPath in
            second.withUnsafeFileSystemRepresentation { secondPath in
                guard let firstPath, let secondPath else {
                    errno = EINVAL
                    return -1
                }
                return renameatx_np(
                    AT_FDCWD,
                    firstPath,
                    AT_FDCWD,
                    secondPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func renameFileAtomically(_ source: URL, _ destination: URL) throws {
        let result: Int32 = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    errno = EINVAL
                    return -1
                }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func removeUnbackedBridgeModules(
        in system32: URL,
        backupDirectory: URL,
        knownRendererModules: [URL]
    ) throws {
        guard !knownRendererModules.isEmpty else { return }

        for moduleName in SafeProcessRunner.rendererBridgeDLLNames {
            let destination = system32.appending(path: moduleName)
            let backup = backupDirectory.appending(path: "\(moduleName).original")
            guard fileManager.fileExists(atPath: destination.path),
                  !fileManager.fileExists(atPath: backup.path) else {
                continue
            }
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(destination, fileManager: fileManager)
            guard isKnownRendererModule(destination, knownRendererModules: knownRendererModules) ||
                Self.hasRendererBridgeMarker(destination, fileManager: fileManager) else {
                continue
            }
            try fileManager.removeItem(at: destination)
        }
    }

    private func isKnownRendererModule(_ file: URL, knownRendererModules: [URL]) -> Bool {
        knownRendererModules.contains { fileManager.contentsEqual(atPath: $0.path, andPath: file.path) }
    }

    private func knownRendererBridgeModulesByWindowsDirectory(
        for runtimeExecutable: URL,
        prefix: URL
    ) throws -> [String: [URL]] {
        var modulesByWindowsDirectory: [String: [URL]] = [:]
        for backend in SteamRendererPolicyPreference.allCases {
            do {
                let modules = try SafeProcessRunner.rendererWindowsModuleFilesByWindowsDirectory(
                    for: runtimeExecutable,
                    graphicsBackend: backend,
                    prefix: prefix
                )
                for (directoryName, directoryModules) in modules {
                    modulesByWindowsDirectory[directoryName, default: []].append(contentsOf: directoryModules)
                }
            } catch {
                throw SteamLaunchError.rendererBridgeInstallFailed(
                    runtimeExecutable,
                    forgePlayTechnicalErrorSummary(error)
                )
            }
        }
        return modulesByWindowsDirectory.mapValues { modules in
            var seen = Set<String>()
            return modules.filter { module in
                seen.insert(module.standardizedFileURL.path).inserted
            }
        }
    }

    private nonisolated static let rendererPolicyWindowsDirectoryNames = [
        "system32",
        "syswow64"
    ]

    private nonisolated static let rendererPolicyDLLNames: Set<String> = [
        "d3d8.dll",
        "d3d9.dll",
        "d3d10.dll",
        "d3d10_1.dll",
        "d3d10core.dll",
        "d3d11.dll",
        "dxgi.dll",
        "d3d12.dll",
        "d3d12core.dll",
        "nvapi64.dll",
        "nvngx.dll",
        "nvngx-on-metalfx.dll",
        "winemetal.dll"
    ]

    private nonisolated static let rendererBridgeFileMarkers = [
        "DXMT",
        "D3DMetal",
        "WineMetalEntry",
        "winemetal.dll",
        "DXVK",
        "dxvk",
        "nvngx-on-metalfx",
        "libd3dshared"
    ]

    private nonisolated static func hasRendererBridgeMarker(_ url: URL, fileManager: FileManager) -> Bool {
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(url, fileManager: fileManager),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let contents = String(data: data, encoding: .utf8) else {
            return false
        }
        return rendererBridgeFileMarkers.contains { contents.localizedCaseInsensitiveContains($0) }
    }
}
