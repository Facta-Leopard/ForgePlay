import Foundation

enum ForgePlayPathRole: String, CaseIterable {
    case apps = "Apps"
    case renderers = "Renderers"
    case appleSupplementalRenderer = "Renderers/AppleD3DMetal"
    case prefixes = "Prefixes"
    case steamSharedPrefix = "Prefixes/SteamShared"
    case steamLibraries = "SteamLibraries"
    case defaultSteamLibrary = "SteamLibraries/DefaultLibrary"
    case runtimeCache = "RuntimeCache"
    case runtimeInstallers = "RuntimeCache/Installers"
    case runtimeExtractedInstallers = "RuntimeCache/ExtractedInstallers"
    case compatibilityDB = "CompatibilityDB"
    case recipes = "CompatibilityDB/recipes"
    case logs = "Logs"
    case launchLogs = "Logs/Launch"
    case installLogs = "Logs/Install"
    case runtimeLogs = "Logs/Runtime"
    case diagnosticLogs = "Logs/Diagnostic"
    case supportBundles = "Logs/SupportBundles"
    case snapshots = "Snapshots"
    case prefixSnapshots = "Snapshots/Prefixes"
    case config = "Config"
}

enum PathManagerError: LocalizedError, Equatable, Hashable {
    case applicationSupportUnavailable
    case rootNotConfigured
    case missing(URL)
    case notWritable(URL)
    case cannotCreate(URL)
    case unsafeDirectory(URL)
    case validationFailed(URL?, String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "ForgePlay 기본 앱 데이터 저장소를 만들 Application Support 위치를 찾을 수 없습니다."
        case .rootNotConfigured:
            "ForgePlay 앱 데이터 위치가 아직 준비되지 않았습니다."
        case .missing(let url):
            "이전 저장 위치를 찾을 수 없습니다: \(url.path)"
        case .notWritable(let url):
            "선택한 위치에 쓸 수 없습니다: \(url.path)"
        case .cannotCreate(let url):
            "필요한 폴더를 만들 수 없습니다: \(url.path)"
        case .unsafeDirectory(let url):
            "선택한 위치가 안전한 일반 폴더가 아닙니다: \(url.path)"
        case .validationFailed(let url, let message):
            if let url {
                "저장 위치를 확인하지 못했습니다: \(url.path). \(message)"
            } else {
                "저장 위치를 확인하지 못했습니다: \(message)"
            }
        }
    }
}

@MainActor
final class PathManager {
    nonisolated static let applicationSupportDirectoryName = "ForgePlay"
    nonisolated static let managedDataDirectoryName = "ManagedData"

    private(set) var rootURL: URL?
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    nonisolated static func defaultManagedRootURL(
        applicationSupportBaseURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let applicationSupport: URL
        if let applicationSupportBaseURL {
            applicationSupport = applicationSupportBaseURL
        } else if let discovered = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            applicationSupport = discovered
        } else {
            throw PathManagerError.applicationSupportUnavailable
        }

        return applicationSupport
            .appending(path: applicationSupportDirectoryName, directoryHint: .isDirectory)
            .appending(path: managedDataDirectoryName, directoryHint: .isDirectory)
            .standardizedFileURL
    }

    func setRoot(_ url: URL?) {
        rootURL = url
    }

    func configureRoot(_ url: URL) throws {
        try createDirectoryIfNeeded(url)
        try validateWritable(url)
        for role in ForgePlayPathRole.allCases {
            try createDirectoryIfNeeded(url.appending(path: role.rawValue, directoryHint: .isDirectory))
        }
        rootURL = url
    }

    func restorePersistedRoot(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PathManagerError.missing(url)
        }
        guard isDirectory.boolValue else {
            throw PathManagerError.unsafeDirectory(url)
        }
        try validateExistingManagedRoot(url)
        rootURL = url
    }

    func restoreWorkflowRoot(_ url: URL?) throws {
        guard let url else {
            rootURL = nil
            return
        }
        do {
            try restorePersistedRoot(url)
        } catch {
            rootURL = nil
            throw error
        }
    }

    func url(for role: ForgePlayPathRole) throws -> URL {
        guard let rootURL else {
            throw PathManagerError.rootNotConfigured
        }
        return rootURL.appending(path: role.rawValue, directoryHint: .isDirectory)
    }

    func validateWritable(_ url: URL) throws {
        try Self.validateWritable(url, fileManager: fileManager)
    }

    func validateExistingManagedRoot(_ url: URL) throws {
        try Self.validateExistingManagedRoot(url, fileManager: fileManager)
    }

    func validateManagedRoot(_ url: URL) throws {
        try Self.validateManagedRoot(url, fileManager: fileManager)
    }

    func validateCurrentManagedRoot() throws -> URL {
        guard let rootURL else {
            throw PathManagerError.rootNotConfigured
        }
        try validateManagedRoot(rootURL)
        return rootURL
    }

    func createLogURL(kind: String, name: String, extension fileExtension: String = "log") throws -> URL {
        let base: ForgePlayPathRole
        switch kind {
        case "launch": base = .launchLogs
        case "runtime": base = .runtimeLogs
        case "diagnostic": base = .diagnosticLogs
        case "install": base = .installLogs
        default: base = .logs
        }
        let folder = try url(for: base)
        try createDirectoryIfNeeded(folder)
        let stamp = Self.timestampFormatter.string(from: Date())
        let safeName = Self.sanitizedFileName(name)
        let safeExtension = Self.sanitizedFileExtension(fileExtension)
        return folder.appending(path: "\(stamp)_\(safeName)_\(kind).\(safeExtension)")
    }

    func createDirectoryIfNeeded(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw PathManagerError.cannotCreate(url)
            }
            try Self.requireNonSymlinkDirectory(url, fileManager: fileManager)
            return
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            if Self.isReadOnlyVolumeError(error) {
                throw PathManagerError.notWritable(url)
            }
            throw PathManagerError.cannotCreate(url)
        }
    }

    private func requireNonSymlinkDirectory(_ url: URL) throws {
        try Self.requireNonSymlinkDirectory(url, fileManager: fileManager)
    }

    nonisolated static func validateExistingManagedRoot(_ url: URL, fileManager: FileManager = .default) throws {
        try requireNonSymlinkDirectory(url, fileManager: fileManager)
        for role in ForgePlayPathRole.allCases {
            let roleURL = url.appending(path: role.rawValue, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: roleURL.path, isDirectory: &isDirectory) else {
                continue
            }
            guard isDirectory.boolValue else {
                throw PathManagerError.cannotCreate(roleURL)
            }
            try requireNonSymlinkDirectory(roleURL, fileManager: fileManager)
        }
    }

    nonisolated static func validateManagedRoot(_ url: URL, fileManager: FileManager = .default) throws {
        try validateExistingManagedRoot(url, fileManager: fileManager)
        try validateWritable(url, fileManager: fileManager)
    }

    private nonisolated static func validateWritable(_ url: URL, fileManager: FileManager) throws {
        let probe = url.appending(path: ".forgeplay-write-test-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try fileManager.removeItem(at: probe)
        } catch {
            throw PathManagerError.notWritable(url)
        }
    }

    private nonisolated static func requireNonSymlinkDirectory(_ url: URL, fileManager: FileManager) throws {
        do {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(url, fileManager: fileManager)
        } catch FileSystemItemPolicyError.notNonSymlinkDirectory {
            throw PathManagerError.unsafeDirectory(url)
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw PathManagerError.validationFailed(url, message)
        } catch {
            throw PathManagerError.validationFailed(url, forgePlayTechnicalErrorSummary(error))
        }
    }

    nonisolated static func isReadOnlyVolumeError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileWriteVolumeReadOnlyError {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == EROFS {
            return true
        }
        return false
    }

    nonisolated static func sanitizedFileName(_ raw: String) -> String {
        var invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        invalid.formUnion(.controlCharacters)
        let scalars = raw.unicodeScalars.map { invalid.contains($0) ? "_" : Character($0) }
        let sanitized = String(scalars)
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "._")))
        let hasContentCharacter = sanitized.unicodeScalars.contains { $0 != "_" && $0 != "." }
        if sanitized.isEmpty || sanitized == "." || sanitized == ".." || !hasContentCharacter {
            return "ForgePlay"
        }
        return String(sanitized.prefix(160))
    }

    nonisolated static func sanitizedFileExtension(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let output = raw.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
        return output.isEmpty ? "log" : String(output.prefix(16))
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
}
