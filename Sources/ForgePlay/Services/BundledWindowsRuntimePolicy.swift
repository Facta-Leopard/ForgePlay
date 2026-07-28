import Foundation

enum ForgePlayBundledWindowsRuntimePolicyError: LocalizedError, Equatable {
    case resourceDirectoryUnavailable
    case runtimeContainerUnavailable(URL, String)
    case runtimeExecutableUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .resourceDirectoryUnavailable:
            "앱 번들 리소스 폴더를 찾을 수 없습니다."
        case .runtimeContainerUnavailable(let url, let message):
            "앱에 포함된 ForgePlay Runtime 폴더를 사용할 수 없습니다: \(url.path). \(message)"
        case .runtimeExecutableUnavailable(let url):
            "앱에 포함된 ForgePlay Runtime에서 실행 파일을 찾지 못했습니다: \(url.path)"
        }
    }
}

enum ForgePlayBundledWindowsRuntimePolicy {
    static let runtimeResourceDirectoryName = "Runners"
    static let runtimeDirectoryName = "ForgePlayRuntime"
    static let runtimeExecutableRelativePath = "wine/bin/wine"

    static func bundledRuntimeExecutableURL(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        return findBundledRuntimeExecutable(inResourceRoot: resourceURL, fileManager: fileManager)
    }

    static func requiredBundledRuntimeExecutableURL(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let resourceURL = bundle.resourceURL else {
            throw ForgePlayBundledWindowsRuntimePolicyError.resourceDirectoryUnavailable
        }
        return try requiredBundledRuntimeExecutable(inResourceRoot: resourceURL, fileManager: fileManager)
    }

    static func isBundledRuntimeExecutable(
        _ url: URL,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let resourceURL = bundle.resourceURL else { return false }
        return isBundledRuntimeExecutable(url, inResourceRoot: resourceURL, fileManager: fileManager)
    }

    static func findBundledRuntimeExecutable(
        inResourceRoot resourceRoot: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        try? requiredBundledRuntimeExecutable(inResourceRoot: resourceRoot, fileManager: fileManager)
    }

    static func requiredBundledRuntimeExecutable(
        inResourceRoot resourceRoot: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let runtimesRoot = resourceRoot
            .appending(path: runtimeResourceDirectoryName, directoryHint: .isDirectory)
        do {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(runtimesRoot, fileManager: fileManager)
        } catch {
            throw ForgePlayBundledWindowsRuntimePolicyError.runtimeContainerUnavailable(
                runtimesRoot,
                forgePlayTechnicalErrorSummary(error)
            )
        }
        let runtimeRoot = runtimesRoot
            .appending(path: runtimeDirectoryName, directoryHint: .isDirectory)
        do {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(runtimeRoot, fileManager: fileManager)
        } catch {
            throw ForgePlayBundledWindowsRuntimePolicyError.runtimeContainerUnavailable(
                runtimeRoot,
                forgePlayTechnicalErrorSummary(error)
            )
        }
        let executable = runtimeRoot
            .appending(path: runtimeExecutableRelativePath, directoryHint: .notDirectory)
            .standardizedFileURL
        guard FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
            from: runtimeRoot,
            to: executable,
            fileManager: fileManager
        ),
        FileSystemItemPolicy.isRegularNonSymlinkFile(executable, fileManager: fileManager),
        fileManager.isExecutableFile(atPath: executable.path) else {
            throw ForgePlayBundledWindowsRuntimePolicyError.runtimeExecutableUnavailable(runtimesRoot)
        }
        return executable
    }

    static func isBundledRuntimeExecutable(
        _ url: URL,
        inResourceRoot resourceRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let runtimeRoot = resourceRoot
            .appending(path: runtimeResourceDirectoryName, directoryHint: .isDirectory)
            .appending(path: runtimeDirectoryName, directoryHint: .isDirectory)
            .standardizedFileURL
        let expected = runtimeRoot
            .appending(path: runtimeExecutableRelativePath, directoryHint: .notDirectory)
            .standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.path == expected.path else { return false }
        guard FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
            from: runtimeRoot,
            to: candidate,
            fileManager: fileManager
        ) else {
            return false
        }
        guard FileSystemItemPolicy.isRegularNonSymlinkFile(candidate, fileManager: fileManager),
              fileManager.isExecutableFile(atPath: candidate.path) else {
            return false
        }
        return true
    }
}
