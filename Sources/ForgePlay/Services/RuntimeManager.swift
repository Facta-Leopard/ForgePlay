import Foundation

struct RuntimeExtractionResult: Hashable {
    var sourceArchive: URL
    var extractionDirectory: URL
    var installer: URL
    var processResult: ProcessRunResult
}

enum RuntimeManagerError: LocalizedError {
    case unsupportedInstaller(URL, RuntimeId)
    case unsupportedExtractionArchive(URL, RuntimeId)
    case unsafeCachedInstaller(URL)
    case metadataReadFailed(URL, String)
    case archiveExtractionFailed(ProcessRunResult)
    case prefixShutdownFailed(ProcessRunResult)
    case extractedInstallerScanFailed(URL, Error)
    case extractedInstallerMissing(URL)
    case extractionCleanupFailed(directory: URL, originalError: Error, cleanupError: Error)
    case cacheCleanupFailed(target: URL, originalError: Error, cleanupError: Error)

    var processResult: ProcessRunResult? {
        switch self {
        case .archiveExtractionFailed(let result),
             .prefixShutdownFailed(let result):
            result
        case .extractionCleanupFailed(_, let originalError, _):
            (originalError as? RuntimeManagerError)?.processResult
        case .unsupportedInstaller,
             .unsupportedExtractionArchive,
             .unsafeCachedInstaller,
             .metadataReadFailed,
             .extractedInstallerScanFailed,
             .extractedInstallerMissing,
             .cacheCleanupFailed:
            nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedInstaller:
            "선택한 설치 파일이 이 필수 구성요소와 맞지 않습니다."
        case .unsupportedExtractionArchive:
            "선택한 파일은 이 필수 구성요소의 압축 해제용 파일이 아닙니다."
        case .unsafeCachedInstaller(let url):
            "Runtime cache 설치 파일은 symlink나 hardlink가 아닌 일반 파일이어야 합니다: \(url.path)"
        case .metadataReadFailed(let url, let message):
            "필수 구성요소 파일 정보를 읽지 못했습니다: \(url.path). \(message)"
        case .archiveExtractionFailed(let result):
            "설치 파일 압축 해제에 실패했습니다. 로그를 확인하세요: \(result.stderrLog.path)"
        case .prefixShutdownFailed(let result):
            "Runtime 설치 전에 Steam 프리픽스 프로세스를 정리하지 못했습니다. 로그를 확인하세요: \(result.stderrLog.path)"
        case .extractedInstallerScanFailed(let directory, let error):
            "압축을 푼 폴더를 읽을 수 없습니다: \(directory.path) (\(forgePlayTechnicalErrorSummary(error)))"
        case .extractedInstallerMissing(let directory):
            "압축을 풀었지만 실행할 설치 파일을 찾지 못했습니다: \(directory.path)"
        case .extractionCleanupFailed(let directory, let originalError, let cleanupError):
            "Runtime 설치 준비에 실패했고 임시 추출 폴더를 정리하지 못했습니다: \(directory.path). 원인: \(forgePlayTechnicalErrorSummary(originalError)). 정리 오류: \(forgePlayTechnicalErrorSummary(cleanupError))"
        case .cacheCleanupFailed(let target, let originalError, let cleanupError):
            "Runtime cache 설치 준비에 실패했고 부분 파일을 정리하지 못했습니다: \(target.path). 원인: \(forgePlayTechnicalErrorSummary(originalError)). 정리 오류: \(forgePlayTechnicalErrorSummary(cleanupError))"
        }
    }
}

@MainActor
final class RuntimeManager {
    private let pathManager: PathManager
    private let runner: SafeProcessRunner
    private let fileManager: FileManager

    init(pathManager: PathManager, runner: SafeProcessRunner, fileManager: FileManager = .default) {
        self.pathManager = pathManager
        self.runner = runner
        self.fileManager = fileManager
    }

    var definitions: [RuntimeDefinition] {
        RuntimeId.allCases.map(definition(for:))
    }

    func definition(for runtime: RuntimeId) -> RuntimeDefinition {
        switch runtime {
        case .vcrun2022, .vcrun2019, .vcrun2017, .vcrun2015:
            return RuntimeDefinition(
                id: runtime,
                officialURL: URL(string: "https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist"),
                officialSourceName: "Microsoft Learn: Latest supported Visual C++ Redistributable",
                beginnerDescription: "많은 Windows 게임이 시작할 때 필요한 Microsoft Visual C++ 구성요소입니다.",
                downloadFileHints: ["vc_redist.x64.exe", "vc_redist.x86.exe"],
                installerHints: ["vc_redist.x64.exe", "vc_redist.x86.exe"],
                preparationNotes: ["64-bit 게임은 vc_redist.x64.exe를 먼저 설치하고, 32-bit/Wow64 로그가 보이면 vc_redist.x86.exe도 같은 프리픽스에 설치합니다."]
            )
        case .vcrun2013:
            return RuntimeDefinition(
                id: runtime,
                officialURL: URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=40784"),
                officialSourceName: "Microsoft Download Center: Visual C++ Redistributable Packages for Visual Studio 2013",
                beginnerDescription: "오래된 Windows 게임에서 필요한 Microsoft Visual C++ 구성요소입니다.",
                downloadFileHints: ["vcredist_x64.exe", "vcredist_x86.exe"],
                installerHints: ["vcredist_x64.exe", "vcredist_x86.exe"],
                preparationNotes: ["msvcr120.dll 또는 msvcp120.dll 오류는 보통 Visual C++ 2013 재배포 패키지로 처리합니다."]
            )
        case .vcrun2012:
            return RuntimeDefinition(
                id: runtime,
                officialURL: URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=30679"),
                officialSourceName: "Microsoft Download Center: Visual C++ Redistributable for Visual Studio 2012 Update 4",
                beginnerDescription: "오래된 Windows 게임에서 필요한 Microsoft Visual C++ 구성요소입니다.",
                downloadFileHints: ["vcredist_x64.exe", "vcredist_x86.exe"],
                installerHints: ["vcredist_x64.exe", "vcredist_x86.exe"],
                preparationNotes: ["msvcr110.dll 또는 msvcp110.dll 오류는 보통 Visual C++ 2012 Update 4 재배포 패키지로 처리합니다."]
            )
        case .vcrun2010:
            return RuntimeDefinition(
                id: runtime,
                officialURL: URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=26999"),
                officialSourceName: "Microsoft Download Center: Visual C++ 2010 SP1 Redistributable",
                beginnerDescription: "오래된 Windows 게임에서 필요한 Microsoft Visual C++ 구성요소입니다.",
                downloadFileHints: ["vcredist_x64.exe", "vcredist_x86.exe"],
                installerHints: ["vcredist_x64.exe", "vcredist_x86.exe"],
                preparationNotes: ["msvcr100.dll 또는 msvcp100.dll 오류는 보통 Visual C++ 2010 SP1 재배포 패키지로 처리합니다."]
            )
        case .d3dx9, .xinput:
            return RuntimeDefinition(
                id: runtime,
                officialURL: URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=35"),
                officialSourceName: "Microsoft Download Center: DirectX End-User Runtime",
                beginnerDescription: "오래된 DirectX 게임에서 필요한 그래픽/입력 구성요소입니다.",
                downloadFileHints: ["dxwebsetup.exe", "directx_Jun2010_redist.exe"],
                installerHints: ["dxwebsetup.exe", "DXSETUP.exe"],
                extractableArchiveHints: ["directx_Jun2010_redist.exe"],
                preparationNotes: ["DirectX June 2010 redist를 받은 경우 ForgePlay에서 그 파일을 선택해도 됩니다. ForgePlay가 압축을 풀고 추출된 DXSETUP.exe를 이어서 실행합니다."]
            )
        case .dotnet48:
            return RuntimeDefinition(
                id: runtime,
                officialURL: URL(string: "https://dotnet.microsoft.com/en-us/download/dotnet-framework/net48"),
                officialSourceName: "Microsoft .NET: .NET Framework 4.8 Runtime",
                beginnerDescription: ".NET으로 만들어진 게임 런처나 도구가 필요로 하는 구성요소입니다.",
                downloadFileHints: ["ndp48-x86-x64-allos-enu.exe", "ndp48-web.exe"],
                installerHints: ["ndp48-x86-x64-allos", "ndp48-web"],
                preparationNotes: ["오프라인 설치 파일(ndp48-x86-x64-allos-enu.exe)을 우선 권장합니다. 웹 설치 파일은 ForgePlay Runtime의 네트워크 상태에 따라 실패할 수 있습니다."]
            )
        case .dotnet40:
            return RuntimeDefinition(
                id: runtime,
                officialURL: URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=17718"),
                officialSourceName: "Microsoft Download Center: .NET Framework 4 Standalone Installer",
                beginnerDescription: ".NET으로 만들어진 게임 런처나 도구가 필요로 하는 구성요소입니다.",
                downloadFileHints: ["dotNetFx40_Full_x86_x64.exe"],
                installerHints: ["dotnetfx40_full", "dotnetfx40"],
                preparationNotes: [".NET 4.0 전용 런처가 아니면 먼저 .NET Framework 4.8을 설치해 보고, 계속 4.0을 요구할 때만 이 설치 파일을 선택합니다."]
            )
        case .openal:
            return RuntimeDefinition(
                id: runtime,
                officialURL: URL(string: "https://www.openal.org/downloads/"),
                officialSourceName: "OpenAL.org Downloads: OpenAL 1.1 Windows Installer",
                beginnerDescription: "일부 게임의 소리 재생에 필요한 OpenAL 구성요소입니다.",
                downloadFileHints: ["OpenAL 1.1 Windows Installer (zip)", "oalinst.exe"],
                installerHints: ["oalinst.exe", "oalinst"],
                preparationNotes: ["OpenAL 페이지에서 zip을 받았다면 먼저 압축을 풀고 내부의 oalinst.exe를 ForgePlay에서 선택합니다."]
            )
        case .xna40:
            return RuntimeDefinition(
                id: runtime,
                officialURL: URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=20914"),
                officialSourceName: "Microsoft Download Center: XNA Framework Redistributable 4.0",
                beginnerDescription: "XNA로 만들어진 일부 인디 게임에 필요한 구성요소입니다.",
                downloadFileHints: ["xnafx40_redist.msi"],
                installerHints: ["xnafx40_redist.msi", "xnafx40"]
            )
        case .physx:
            return RuntimeDefinition(
                id: runtime,
                officialURL: URL(string: "https://www.nvidia.com/en-us/drivers/physx/physx-9-19-0218-driver/"),
                officialSourceName: "NVIDIA: PhysX System Software",
                beginnerDescription: "일부 오래된 게임의 물리 효과에 필요한 PhysX 구성요소입니다.",
                downloadFileHints: ["PhysX-9.19.0218-SystemSoftware.exe", "PhysX_System_Software_Legacy_Driver.exe"],
                installerHints: ["physx"],
                preparationNotes: ["2007년 전후 AGEIA/legacy PhysX 게임이면 NVIDIA 페이지의 Legacy Installer 링크에서 받은 설치 파일을 같은 프리픽스에 추가로 설치합니다."]
            )
        }
    }

    func isInstaller(_ url: URL, plausibleFor runtime: RuntimeId) -> Bool {
        let lowerName = url.lastPathComponent.lowercased()
        let allowedExtension = Self.allowedInstallerExtensions.contains(url.pathExtension.lowercased())
        let matchingName = definition(for: runtime).installerHints.contains { lowerName.contains($0.lowercased()) }
        return isRegularInstallCandidate(url) && allowedExtension && matchingName
    }

    func isExtractionArchive(_ url: URL, plausibleFor runtime: RuntimeId) -> Bool {
        let lowerName = url.lastPathComponent.lowercased()
        let allowedExtension = url.pathExtension.lowercased() == "exe"
        let matchingName = definition(for: runtime).extractableArchiveHints.contains { lowerName == $0.lowercased() }
        return isRegularInstallCandidate(url) && allowedExtension && matchingName
    }

    static let allowedInstallerExtensions = ["exe", "msi"]

    func extractInstaller(
        runtime: RuntimeId,
        archive: URL,
        runtimeExecutable: URL,
        prefixURL: URL
    ) async throws -> RuntimeExtractionResult {
        try requireRegularExtractionArchiveCandidate(archive, runtime: runtime)
        guard isExtractionArchive(archive, plausibleFor: runtime) else {
            throw RuntimeManagerError.unsupportedExtractionArchive(archive, runtime)
        }

        let cachedArchive = try cacheInstallerIfNeeded(archive)
        let extractionDirectory = try createExtractionDirectory(runtime: runtime, archive: archive)
        let logDirectory = try pathManager.url(for: .runtimeLogs)
        do {
            let result = try await runner.run(.extractRuntimeArchive(
                runtimeExecutable: runtimeExecutable,
                prefix: prefixURL,
                archive: cachedArchive,
                extractionDirectory: extractionDirectory,
                runtime: runtime,
                logDirectory: logDirectory
            ))
            guard result.succeeded else {
                throw RuntimeManagerError.archiveExtractionFailed(result)
            }
            guard let installer = try findInstaller(in: extractionDirectory, runtime: runtime) else {
                throw RuntimeManagerError.extractedInstallerMissing(extractionDirectory)
            }

            return RuntimeExtractionResult(
                sourceArchive: archive,
                extractionDirectory: extractionDirectory,
                installer: installer,
                processResult: result
            )
        } catch {
            do {
                try cleanupExtractionDirectory(extractionDirectory)
            } catch let cleanupError {
                throw RuntimeManagerError.extractionCleanupFailed(
                    directory: extractionDirectory,
                    originalError: error,
                    cleanupError: cleanupError
                )
            }
            throw error
        }
    }

    func install(runtime: RuntimeId, installer: URL, runtimeExecutable: URL, prefixURL: URL) async throws -> ProcessRunResult {
        try requireRegularInstallCandidate(installer, runtime: runtime)
        guard isInstaller(installer, plausibleFor: runtime) else {
            throw RuntimeManagerError.unsupportedInstaller(installer, runtime)
        }
        let logDirectory = try pathManager.url(for: .runtimeLogs)
        let cachedInstaller = try cacheInstallerIfNeeded(installer)
        return try await runner.run(.installRuntime(
            runtimeExecutable: runtimeExecutable,
            prefix: prefixURL,
            installer: cachedInstaller,
            runtime: runtime,
            logDirectory: logDirectory
        ))
    }

    func shutdownPrefixBeforeMutation(
        runtimeExecutable: URL,
        prefixURL: URL
    ) async throws {
        let logDirectory = try pathManager.url(for: .runtimeLogs)
        let result = try await runner.run(.shutdownWinePrefix(
            runtimeExecutable: runtimeExecutable,
            prefix: prefixURL,
            logDirectory: logDirectory
        ))
        guard result.succeeded else {
            throw RuntimeManagerError.prefixShutdownFailed(result)
        }
    }

    func withQuiescentPrefixMutation<T>(
        runtimeExecutable: URL,
        prefixURL: URL,
        operationDescription: String,
        perform body: () async throws -> T
    ) async throws -> T {
        try await shutdownPrefixBeforeMutation(
            runtimeExecutable: runtimeExecutable,
            prefixURL: prefixURL
        )

        let value: T
        do {
            value = try await body()
        } catch {
            do {
                try await shutdownPrefixBeforeMutation(
                    runtimeExecutable: runtimeExecutable,
                    prefixURL: prefixURL
                )
            } catch let cleanupError {
                throw SteamPrefixLifecycleCleanupError(
                    originalDescription: forgePlayTechnicalErrorSummary(error),
                    cleanupDescription: forgePlayTechnicalErrorSummary(cleanupError),
                    originalError: error,
                    cleanupError: cleanupError,
                    originalProcessResult: diagnosticProcessRunResult(from: error),
                    cleanupProcessResults: diagnosticProcessRunResults(from: cleanupError)
                )
            }
            throw error
        }

        do {
            try await shutdownPrefixBeforeMutation(
                runtimeExecutable: runtimeExecutable,
                prefixURL: prefixURL
            )
        } catch {
            throw SteamPrefixLifecycleCleanupError(
                originalDescription: operationDescription,
                cleanupDescription: forgePlayTechnicalErrorSummary(error),
                cleanupError: error,
                cleanupProcessResults: diagnosticProcessRunResults(from: error)
            )
        }
        return value
    }

    /// Copies a user-selected installer into ForgePlay-managed storage and
    /// returns the managed URL that sandboxed Wine children may safely open.
    private func cacheInstallerIfNeeded(_ installer: URL) throws -> URL {
        let cache = try pathManager.url(for: .runtimeInstallers)
        try pathManager.createDirectoryIfNeeded(cache)
        let target = cache.appending(path: Self.sanitizedCacheFileName(for: installer))
        if cachedInstallerTargetExists(target) {
            try validateCachedInstallerTarget(target)
            return target
        }
        let temporaryTarget = cache.appending(path: ".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        var didMoveTemporaryToTarget = false
        do {
            try fileManager.copyItem(at: installer, to: temporaryTarget)
            try validateCachedInstallerTarget(temporaryTarget)
            try fileManager.moveItem(at: temporaryTarget, to: target)
            didMoveTemporaryToTarget = true
            try validateCachedInstallerTarget(target)
        } catch {
            do {
                try removeCacheArtifactIfPresent(temporaryTarget)
            } catch let cleanupError {
                throw RuntimeManagerError.cacheCleanupFailed(
                    target: temporaryTarget,
                    originalError: error,
                    cleanupError: cleanupError
                )
            }
            if didMoveTemporaryToTarget {
                do {
                    try removeCacheArtifactIfPresent(target)
                } catch let cleanupError {
                    throw RuntimeManagerError.cacheCleanupFailed(
                        target: target,
                        originalError: error,
                        cleanupError: cleanupError
                    )
                }
            }
            throw error
        }
        return target
    }

    private func removeCacheArtifactIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) ||
            (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private func cachedInstallerTargetExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) ||
            (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func validateCachedInstallerTarget(_ url: URL) throws {
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: url.path)
            } catch {
                throw RuntimeManagerError.metadataReadFailed(url, forgePlayTechnicalErrorSummary(error))
            }
            let referenceCount = (attributes[.referenceCount] as? NSNumber)?.intValue ?? 1
            guard referenceCount == 1 else {
                throw RuntimeManagerError.unsafeCachedInstaller(url)
            }
        } catch FileSystemItemPolicyError.notRegularNonSymlinkFile {
            throw RuntimeManagerError.unsafeCachedInstaller(url)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw RuntimeManagerError.metadataReadFailed(url, message)
        } catch let error as RuntimeManagerError {
            throw error
        } catch {
            throw RuntimeManagerError.metadataReadFailed(url, forgePlayTechnicalErrorSummary(error))
        }
    }

    private func isRegularInstallCandidate(_ url: URL) -> Bool {
        FileSystemItemPolicy.isRegularNonSymlinkFile(url, fileManager: fileManager)
    }

    private func requireRegularInstallCandidate(_ url: URL, runtime: RuntimeId) throws {
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw RuntimeManagerError.metadataReadFailed(url, message)
        } catch {
            throw RuntimeManagerError.unsupportedInstaller(url, runtime)
        }
    }

    private func requireRegularExtractionArchiveCandidate(_ url: URL, runtime: RuntimeId) throws {
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw RuntimeManagerError.metadataReadFailed(url, message)
        } catch {
            throw RuntimeManagerError.unsupportedExtractionArchive(url, runtime)
        }
    }

    private nonisolated static func sanitizedCacheFileName(for url: URL) -> String {
        let baseName = PathManager.sanitizedFileName(url.deletingPathExtension().lastPathComponent)
        let fileExtension = PathManager.sanitizedFileExtension(url.pathExtension)
        return "\(baseName).\(fileExtension)"
    }

    private func createExtractionDirectory(runtime: RuntimeId, archive: URL) throws -> URL {
        let root = try pathManager.url(for: .runtimeExtractedInstallers)
        try pathManager.createDirectoryIfNeeded(root)
        let folderName = PathManager.sanitizedFileName(
            "\(runtime.rawValue)-\(archive.deletingPathExtension().lastPathComponent)-\(UUID().uuidString)"
        )
        let directory = root.appending(path: folderName, directoryHint: .isDirectory)
        try pathManager.createDirectoryIfNeeded(directory)
        return directory
    }

    private func cleanupExtractionDirectory(_ directory: URL) throws {
        guard try isExistingNonSymlinkDirectory(directory) else {
            return
        }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            try restoreWritablePermissions(in: directory)
            try fileManager.removeItem(at: directory)
        }
    }

    private func restoreWritablePermissions(in directory: URL) throws {
        guard try isExistingNonSymlinkDirectory(directory) else {
            return
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { continue }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        if let enumerationError {
            throw enumerationError
        }
    }

    private func isExistingNonSymlinkDirectory(_ url: URL) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        do {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(url, fileManager: fileManager)
            return true
        } catch FileSystemItemPolicyError.notNonSymlinkDirectory {
            return false
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw RuntimeManagerError.metadataReadFailed(url, message)
        } catch {
            throw RuntimeManagerError.metadataReadFailed(url, forgePlayTechnicalErrorSummary(error))
        }
    }

    private func findInstaller(in directory: URL, runtime: RuntimeId) throws -> URL? {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw RuntimeManagerError.extractedInstallerScanFailed(directory, error)
        }
        if let direct = contents.first(where: { isInstaller($0, plausibleFor: runtime) }) {
            return direct
        }

        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw RuntimeManagerError.extractedInstallerScanFailed(
                directory,
                CocoaError(.fileReadUnknown)
            )
        }
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch {
                throw RuntimeManagerError.extractedInstallerScanFailed(directory, error)
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if isInstaller(url, plausibleFor: runtime) {
                return url
            }
        }
        if let enumerationError {
            throw RuntimeManagerError.extractedInstallerScanFailed(directory, enumerationError)
        }
        return nil
    }
}
