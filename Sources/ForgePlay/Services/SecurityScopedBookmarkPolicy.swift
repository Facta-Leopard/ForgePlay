import Foundation
import Security

enum PersistedFileSelectionRole: String, CaseIterable, Hashable {
    case selectedRoot
    case steamInstaller
    case steamLibrary

    var displayNameKey: String {
        switch self {
        case .selectedRoot: "ForgePlay 앱 데이터 위치"
        case .steamInstaller: "Steam 설치 파일"
        case .steamLibrary: "외장 Steam 라이브러리"
        }
    }
}

struct SecurityScopedBookmarkAccess: Sendable {
    var url: URL
    var isStale: Bool
    var didStartSecurityScope: Bool
}

struct SecurityScopedBookmarkResolvedURL: Sendable {
    var url: URL
    var isStale: Bool
}

struct SecurityScopedBookmarkFailure: Error, Equatable {
    var role: PersistedFileSelectionRole
    var savedPath: String?
    var reason: String
}

struct SecurityScopedBookmarkCreationFailure: Error, Equatable {
    var role: PersistedFileSelectionRole
    var path: String
    var reason: String
}

enum SecurityScopedBookmarkResolution {
    case restored(SecurityScopedBookmarkAccess)
    case pathFallback(URL)
    case unavailable(SecurityScopedBookmarkFailure)
    case empty

    var url: URL? {
        switch self {
        case .restored(let access): access.url
        case .pathFallback(let url): url
        case .unavailable, .empty: nil
        }
    }
}

enum SecurityScopedBookmarkPolicy {
    static func createBookmarkData(
        for url: URL,
        role: PersistedFileSelectionRole,
        bookmarkCreator: (URL) throws -> Data = { try SecurityScopedBookmarkPolicy.bookmarkData(for: $0) }
    ) -> Result<Data, SecurityScopedBookmarkCreationFailure> {
        do {
            return .success(try bookmarkCreator(url))
        } catch {
            return .failure(SecurityScopedBookmarkCreationFailure(
                role: role,
                path: url.path,
                reason: bookmarkCreationFailureReason(error)
            ))
        }
    }

    static func resolve(
        path: String?,
        bookmark: Data?,
        role: PersistedFileSelectionRole,
        allowsPathFallback: Bool = true,
        fileManager: FileManager = .default,
        bookmarkResolver: (Data) throws -> SecurityScopedBookmarkResolvedURL = { try SecurityScopedBookmarkPolicy.resolvedURL(fromBookmarkData: $0) },
        securityScopeStarter: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    ) -> SecurityScopedBookmarkResolution {
        let cleanPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let bookmark, !bookmark.isEmpty {
            do {
                let resolved = try bookmarkResolver(bookmark)
                let didStart = securityScopeStarter(resolved.url)
                guard didStart else {
                    return pathFallbackAfterBookmarkFailure(
                        SecurityScopedBookmarkFailure(
                            role: role,
                            savedPath: cleanPath,
                            reason: "security-scoped resource access could not be started"
                        ),
                        cleanPath: cleanPath,
                        allowsPathFallback: allowsPathFallback,
                        role: role,
                        fileManager: fileManager
                    )
                }
                return .restored(SecurityScopedBookmarkAccess(
                    url: resolved.url,
                    isStale: resolved.isStale,
                    didStartSecurityScope: true
                ))
            } catch {
                return pathFallbackAfterBookmarkFailure(
                    SecurityScopedBookmarkFailure(
                        role: role,
                        savedPath: cleanPath,
                        reason: forgePlayTechnicalErrorSummary(error)
                    ),
                    cleanPath: cleanPath,
                    allowsPathFallback: allowsPathFallback,
                    role: role,
                    fileManager: fileManager
                )
            }
        }

        guard let cleanPath, !cleanPath.isEmpty else {
            return .empty
        }
        guard allowsPathFallback else {
            return .unavailable(SecurityScopedBookmarkFailure(
                role: role,
                savedPath: cleanPath,
                reason: "security-scoped bookmark is missing"
            ))
        }
        let fallbackURL = URL(fileURLWithPath: cleanPath)
        if let validationFailure = pathFallbackValidationFailure(
            for: fallbackURL,
            role: role,
            fileManager: fileManager
        ) {
            return .unavailable(SecurityScopedBookmarkFailure(
                role: role,
                savedPath: cleanPath,
                reason: validationFailure
            ))
        }
        return .pathFallback(fallbackURL)
    }

    private static func pathFallbackAfterBookmarkFailure(
        _ failure: SecurityScopedBookmarkFailure,
        cleanPath: String?,
        allowsPathFallback: Bool,
        role: PersistedFileSelectionRole,
        fileManager: FileManager
    ) -> SecurityScopedBookmarkResolution {
        guard allowsPathFallback,
              let cleanPath,
              !cleanPath.isEmpty else {
            return .unavailable(failure)
        }
        let fallbackURL = URL(fileURLWithPath: cleanPath)
        guard pathFallbackValidationFailure(for: fallbackURL, role: role, fileManager: fileManager) == nil else {
            return .unavailable(failure)
        }
        return .pathFallback(fallbackURL)
    }

    private static func bookmarkCreationFailureReason(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return description
        }
        return forgePlayTechnicalErrorSummary(error)
    }

    static func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolvedURL(fromBookmarkData bookmark: Data) throws -> SecurityScopedBookmarkResolvedURL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return SecurityScopedBookmarkResolvedURL(url: url, isStale: isStale)
    }

    private static func pathFallbackValidationFailure(
        for url: URL,
        role: PersistedFileSelectionRole,
        fileManager: FileManager
    ) -> String? {
        do {
            switch role {
            case .selectedRoot:
                try FileSystemItemPolicy.requireNonSymlinkDirectory(url, fileManager: fileManager)
            case .steamInstaller:
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
                guard url.pathExtension.lowercased() == "exe" else {
                    return "saved path is not a SteamSetup.exe file"
                }
            case .steamLibrary:
                try FileSystemItemPolicy.requireNonSymlinkDirectory(url, fileManager: fileManager)
            }
            return nil
        } catch {
            return forgePlayTechnicalErrorSummary(error)
        }
    }
}

enum ForgePlaySandboxPolicy {
    static var isAppSandboxEnabled: Bool {
        #if FORGEPLAY_APP_STORE || FORGEPLAY_SANDBOXED_DISTRIBUTION
        return true
        #else
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.app-sandbox" as CFString,
                nil
              ) else {
            return false
        }
        return (value as? Bool) == true
        #endif
    }

    static var primaryApplicationGroupIdentifier: String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.application-groups" as CFString,
                nil
              ) as? [String] else {
            return nil
        }
        return value.first { identifier in
            !identifier.isEmpty && !identifier.contains("$(")
        }
    }
}
