import CryptoKit
import Darwin
import Foundation

/// Runtime installer archives can be hundreds of megabytes. Move their cache
/// and extraction-tree I/O off the main actor while preserving the injected
/// filesystem boundary used by tests.
private struct RuntimeManagerFileManagerReference: @unchecked Sendable {
    let value: FileManager
}

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
    case extractionCleanupAfterUseFailed(directory: URL, cleanupError: Error)
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
             .extractionCleanupAfterUseFailed,
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
        case .extractionCleanupAfterUseFailed(let directory, let cleanupError):
            "Runtime 설치 후 임시 추출 폴더를 정리하지 못했습니다: \(directory.path). 정리 오류: \(forgePlayTechnicalErrorSummary(cleanupError))"
        case .cacheCleanupFailed(let target, let originalError, let cleanupError):
            "Runtime cache 설치 준비에 실패했고 부분 파일을 정리하지 못했습니다: \(target.path). 원인: \(forgePlayTechnicalErrorSummary(originalError)). 정리 오류: \(forgePlayTechnicalErrorSummary(cleanupError))"
        }
    }
}

@MainActor
final class RuntimeManager {
    private struct AuthenticatedInstallerFile: Sendable {
        let device: UInt64
        let inode: UInt64
        let byteCount: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
        let contentSHA256: String
    }

    private let pathManager: PathManager
    private let runner: SafeProcessRunner
    private let fileManager: FileManager

    init(pathManager: PathManager, runner: SafeProcessRunner, fileManager: FileManager = .default) {
        self.pathManager = pathManager
        self.runner = runner
        self.fileManager = fileManager
    }

    private nonisolated static func runCancellableFilesystemTask<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let worker = Task.detached(priority: priority) {
            try operation()
        }
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            worker.cancel()
        }
    }

    private nonisolated static func runMandatoryFilesystemTask<T: Sendable>(
        priority: TaskPriority = .utility,
        operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: priority) {
            try operation()
        }.value
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

    nonisolated static let allowedInstallerExtensions = ["exe", "msi"]

    private func extractInstaller(
        runtime: RuntimeId,
        archive: URL,
        runtimeExecutable: URL,
        prefixURL: URL
    ) async throws -> RuntimeExtractionResult {
        try requireRegularExtractionArchiveCandidate(archive, runtime: runtime)
        guard isExtractionArchive(archive, plausibleFor: runtime) else {
            throw RuntimeManagerError.unsupportedExtractionArchive(archive, runtime)
        }

        let cachedArchive = try await cacheInstallerIfNeeded(archive)
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
            guard let installer = try await findInstaller(in: extractionDirectory, runtime: runtime) else {
                throw RuntimeManagerError.extractedInstallerMissing(extractionDirectory)
            }

            return RuntimeExtractionResult(
                sourceArchive: archive,
                extractionDirectory: extractionDirectory,
                installer: installer,
                processResult: result
            )
        } catch let originalError {
            do {
                try await cleanupExtractionDirectory(extractionDirectory)
            } catch let cleanupError {
                throw RuntimeManagerError.extractionCleanupFailed(
                    directory: extractionDirectory,
                    originalError: originalError,
                    cleanupError: cleanupError
                )
            }
            throw originalError
        }
    }

    /// Keeps the extracted installer tree alive only while `body` uses it.
    /// Cleanup is mandatory after success, failure, or cancellation so repeated
    /// DirectX redist installs cannot accumulate unbounded extracted payloads.
    func withExtractedInstaller<T>(
        runtime: RuntimeId,
        archive: URL,
        runtimeExecutable: URL,
        prefixURL: URL,
        perform body: (RuntimeExtractionResult) async throws -> T
    ) async throws -> T {
        let extraction = try await extractInstaller(
            runtime: runtime,
            archive: archive,
            runtimeExecutable: runtimeExecutable,
            prefixURL: prefixURL
        )
        let outcome: Result<T, any Error>
        do {
            outcome = .success(try await body(extraction))
        } catch {
            outcome = .failure(error)
        }

        do {
            try await cleanupExtractionDirectory(extraction.extractionDirectory)
        } catch let cleanupError {
            switch outcome {
            case .success:
                throw RuntimeManagerError.extractionCleanupAfterUseFailed(
                    directory: extraction.extractionDirectory,
                    cleanupError: cleanupError
                )
            case .failure(let originalError):
                throw RuntimeManagerError.extractionCleanupFailed(
                    directory: extraction.extractionDirectory,
                    originalError: originalError,
                    cleanupError: cleanupError
                )
            }
        }

        switch outcome {
        case .success(let value):
            try Task.checkCancellation()
            return value
        case .failure(let error):
            throw error
        }
    }

    func install(runtime: RuntimeId, installer: URL, runtimeExecutable: URL, prefixURL: URL) async throws -> ProcessRunResult {
        try requireRegularInstallCandidate(installer, runtime: runtime)
        guard isInstaller(installer, plausibleFor: runtime) else {
            throw RuntimeManagerError.unsupportedInstaller(installer, runtime)
        }
        let logDirectory = try pathManager.url(for: .runtimeLogs)
        let cachedInstaller = try await cacheInstallerIfNeeded(installer)
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
    private func cacheInstallerIfNeeded(_ installer: URL) async throws -> URL {
        let cache = try pathManager.url(for: .runtimeInstallers)
        try pathManager.createDirectoryIfNeeded(cache)
        let filesystem = RuntimeManagerFileManagerReference(value: fileManager)
        return try await Self.runCancellableFilesystemTask {
            try Self.cacheInstallerIfNeeded(
                installer,
                cache: cache,
                fileManager: filesystem.value
            )
        }
    }

    private nonisolated static func cacheInstallerIfNeeded(
        _ installer: URL,
        cache: URL,
        fileManager: FileManager
    ) throws -> URL {
        try Task.checkCancellation()
        let sourceIdentity = try authenticatedInstallerFile(at: installer)
        let target = cache.appending(
            path: contentAddressedCacheFileName(
                for: installer,
                contentSHA256: sourceIdentity.contentSHA256
            )
        )
        if cachedInstallerTargetExists(target, fileManager: fileManager) {
            _ = try authenticatedInstallerFile(
                at: target,
                expectedContentSHA256: sourceIdentity.contentSHA256
            )
            return target
        }
        let temporaryTarget = cache.appending(path: ".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try fileManager.copyItem(at: installer, to: temporaryTarget)
            try Task.checkCancellation()
            _ = try authenticatedInstallerFile(
                at: temporaryTarget,
                expectedContentSHA256: sourceIdentity.contentSHA256
            )
        } catch let originalError {
            do {
                try removeCacheArtifactIfPresent(temporaryTarget, fileManager: fileManager)
            } catch let cleanupError {
                throw RuntimeManagerError.cacheCleanupFailed(
                    target: temporaryTarget,
                    originalError: originalError,
                    cleanupError: cleanupError
                )
            }
            throw originalError
        }

        do {
            try fileManager.moveItem(at: temporaryTarget, to: target)
        } catch let moveError {
            do {
                try removeCacheArtifactIfPresent(temporaryTarget, fileManager: fileManager)
            } catch let cleanupError {
                throw RuntimeManagerError.cacheCleanupFailed(
                    target: temporaryTarget,
                    originalError: moveError,
                    cleanupError: cleanupError
                )
            }
            // Another cache request for the same bytes may have published the
            // immutable content-address concurrently. Reuse it only after an
            // independent descriptor-bound fingerprint readback.
            if cachedInstallerTargetExists(target, fileManager: fileManager) {
                _ = try authenticatedInstallerFile(
                    at: target,
                    expectedContentSHA256: sourceIdentity.contentSHA256
                )
                return target
            }
            throw moveError
        }

        _ = try authenticatedInstallerFile(
            at: target,
            expectedContentSHA256: sourceIdentity.contentSHA256
        )
        return target
    }

    private nonisolated static func removeCacheArtifactIfPresent(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) ||
            (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private nonisolated static func cachedInstallerTargetExists(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        fileManager.fileExists(atPath: url.path) ||
            (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Opens and fingerprints one exact file object. The before/after `fstat`
    /// identity checks reject replacements and in-place mutation while the
    /// digest is being read; callers never trust a path-only metadata check.
    private nonisolated static func authenticatedInstallerFile(
        at url: URL,
        expectedContentSHA256: String? = nil
    ) throws -> AuthenticatedInstallerFile {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            let openError = errno
            var pathStatus = stat()
            if Darwin.lstat(url.path, &pathStatus) == 0,
               (pathStatus.st_mode & S_IFMT) == S_IFLNK {
                throw RuntimeManagerError.unsafeCachedInstaller(url)
            }
            throw RuntimeManagerError.metadataReadFailed(
                url,
                String(cString: strerror(openError))
            )
        }
        defer { Darwin.close(descriptor) }

        var initialStatus = stat()
        guard Darwin.fstat(descriptor, &initialStatus) == 0 else {
            throw RuntimeManagerError.metadataReadFailed(
                url,
                String(cString: strerror(errno))
            )
        }
        guard (initialStatus.st_mode & S_IFMT) == S_IFREG,
              initialStatus.st_nlink == 1,
              initialStatus.st_size >= 0 else {
            throw RuntimeManagerError.unsafeCachedInstaller(url)
        }

        var hasher = SHA256()
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while offset < initialStatus.st_size {
            try Task.checkCancellation()
            let requested = min(
                buffer.count,
                Int(initialStatus.st_size - offset)
            )
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(
                    descriptor,
                    bytes.baseAddress,
                    requested,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw RuntimeManagerError.metadataReadFailed(
                    url,
                    count < 0
                        ? String(cString: strerror(errno))
                        : "파일을 fingerprint하는 동안 내용이 변경되었습니다."
                )
            }
            hasher.update(data: Data(buffer.prefix(count)))
            offset += Int64(count)
        }
        let contentSHA256 = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()

        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0 else {
            throw RuntimeManagerError.metadataReadFailed(
                url,
                String(cString: strerror(errno))
            )
        }
        let identity = AuthenticatedInstallerFile(
            device: UInt64(finalStatus.st_dev),
            inode: UInt64(finalStatus.st_ino),
            byteCount: Int64(finalStatus.st_size),
            modificationSeconds: Int64(finalStatus.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(finalStatus.st_mtimespec.tv_nsec),
            changeSeconds: Int64(finalStatus.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(finalStatus.st_ctimespec.tv_nsec),
            contentSHA256: contentSHA256
        )
        guard identity.device == UInt64(initialStatus.st_dev),
              identity.inode == UInt64(initialStatus.st_ino),
              identity.byteCount == Int64(initialStatus.st_size),
              identity.modificationSeconds == Int64(initialStatus.st_mtimespec.tv_sec),
              identity.modificationNanoseconds == Int64(initialStatus.st_mtimespec.tv_nsec),
              identity.changeSeconds == Int64(initialStatus.st_ctimespec.tv_sec),
              identity.changeNanoseconds == Int64(initialStatus.st_ctimespec.tv_nsec) else {
            throw RuntimeManagerError.metadataReadFailed(
                url,
                "파일을 fingerprint하는 동안 파일 객체가 변경되었습니다."
            )
        }
        if let expectedContentSHA256,
           identity.contentSHA256 != expectedContentSHA256 {
            throw RuntimeManagerError.unsafeCachedInstaller(url)
        }
        return identity
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

    nonisolated static func contentAddressedCacheFileName(
        for url: URL,
        contentSHA256: String
    ) -> String {
        let sanitizedBaseName = PathManager.sanitizedFileName(
            url.deletingPathExtension().lastPathComponent
        )
        var baseName = ""
        var baseNameByteCount = 0
        for character in sanitizedBaseName {
            let characterByteCount = String(character).utf8.count
            guard baseNameByteCount + characterByteCount <= 120 else { break }
            baseName.append(character)
            baseNameByteCount += characterByteCount
        }
        if baseName.isEmpty { baseName = "ForgePlay" }
        let fileExtension = PathManager.sanitizedFileExtension(url.pathExtension)
        return "\(baseName)-\(contentSHA256.lowercased()).\(fileExtension)"
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

    private func cleanupExtractionDirectory(_ directory: URL) async throws {
        let filesystem = RuntimeManagerFileManagerReference(value: fileManager)
        try await Self.runMandatoryFilesystemTask {
            try Self.cleanupExtractionDirectory(
                directory,
                fileManager: filesystem.value
            )
        }
    }

    private nonisolated static func cleanupExtractionDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        guard try isExistingNonSymlinkDirectory(directory, fileManager: fileManager) else {
            return
        }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            try restoreWritablePermissions(in: directory, fileManager: fileManager)
            try fileManager.removeItem(at: directory)
        }
    }

    private nonisolated static func restoreWritablePermissions(
        in directory: URL,
        fileManager: FileManager
    ) throws {
        guard try isExistingNonSymlinkDirectory(directory, fileManager: fileManager) else {
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

    private nonisolated static func isExistingNonSymlinkDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws -> Bool {
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

    private func findInstaller(in directory: URL, runtime: RuntimeId) async throws -> URL? {
        let installerHints = definition(for: runtime).installerHints
        let filesystem = RuntimeManagerFileManagerReference(value: fileManager)
        return try await Self.runCancellableFilesystemTask(priority: .utility) {
            try Self.findInstaller(
                in: directory,
                installerHints: installerHints,
                fileManager: filesystem.value
            )
        }
    }

    private nonisolated static func findInstaller(
        in directory: URL,
        installerHints: [String],
        fileManager: FileManager
    ) throws -> URL? {
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
        try Task.checkCancellation()
        if let direct = contents.first(where: {
            isInstaller($0, matching: installerHints, fileManager: fileManager)
        }) {
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
            try Task.checkCancellation()
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
            if isInstaller(url, matching: installerHints, fileManager: fileManager) {
                return url
            }
        }
        if let enumerationError {
            throw RuntimeManagerError.extractedInstallerScanFailed(directory, enumerationError)
        }
        return nil
    }

    private nonisolated static func isInstaller(
        _ url: URL,
        matching installerHints: [String],
        fileManager: FileManager
    ) -> Bool {
        let lowerName = url.lastPathComponent.lowercased()
        let allowedExtension = allowedInstallerExtensions.contains(url.pathExtension.lowercased())
        let matchingName = installerHints.contains { lowerName.contains($0.lowercased()) }
        return FileSystemItemPolicy.isRegularNonSymlinkFile(url, fileManager: fileManager) &&
            allowedExtension &&
            matchingName
    }
}
