import Foundation

enum SteamUISurface: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case signIn
    case steamGuard
    case library
}

enum SteamSessionArtifactState: String, Codable, CaseIterable, Hashable, Sendable {
    case unavailable
    case noAccountData
    case accountDataPresent
    case rememberedSignInConfigured
    case invalid
}

struct SteamSessionInspection: Hashable, Sendable {
    var state: SteamSessionArtifactState
    var accountCount: Int
    var userDataDirectoryCount: Int
    var issue: String?

    static let unavailable = SteamSessionInspection(
        state: .unavailable,
        accountCount: 0,
        userDataDirectoryCount: 0,
        issue: nil
    )

    var hasLocalAccountData: Bool {
        accountCount > 0 || userDataDirectoryCount > 0
    }
}

enum SteamSessionContinuityState: String, Codable, CaseIterable, Hashable, Sendable {
    case notVerified
    case libraryVerifiedOnce
    case libraryVerifiedAfterRelaunch
}

final class SteamSessionStateInspector: @unchecked Sendable {
    static let maxLoginUsersBytes = 256 * 1024

    private let fileManager: FileManager
    private let parser: VDFParser

    init(fileManager: FileManager = .default, parser: VDFParser = VDFParser()) {
        self.fileManager = fileManager
        self.parser = parser
    }

    func inspect(prefix: URL) -> SteamSessionInspection {
        let steamDirectory = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        guard fileManager.fileExists(atPath: steamDirectory.path) else {
            return .unavailable
        }
        guard FileSystemItemPolicy.isNonSymlinkDirectory(steamDirectory, fileManager: fileManager) else {
            return invalid("Steam installation directory is not a safe regular directory")
        }

        let loginUsers = steamDirectory.appending(path: "config/loginusers.vdf")
        let accountResult: (count: Int, remembersSignIn: Bool)
        do {
            accountResult = try inspectLoginUsers(at: loginUsers)
        } catch {
            return invalid("loginusers.vdf could not be inspected: \(forgePlayTechnicalErrorSummary(error))")
        }

        let userDataResult: Int
        do {
            userDataResult = try inspectUserDataDirectories(
                at: steamDirectory.appending(path: "userdata", directoryHint: .isDirectory)
            )
        } catch {
            return invalid("Steam userdata could not be inspected: \(forgePlayTechnicalErrorSummary(error))")
        }

        let state: SteamSessionArtifactState
        if accountResult.remembersSignIn {
            state = .rememberedSignInConfigured
        } else if accountResult.count > 0 || userDataResult > 0 {
            state = .accountDataPresent
        } else {
            state = .noAccountData
        }
        return SteamSessionInspection(
            state: state,
            accountCount: accountResult.count,
            userDataDirectoryCount: userDataResult,
            issue: nil
        )
    }

    private func inspectLoginUsers(at url: URL) throws -> (count: Int, remembersSignIn: Bool) {
        guard fileManager.fileExists(atPath: url.path) else {
            return (0, false)
        }
        guard try SteamVDFFileReader.isReadableTextFile(
            url,
            maxBytes: Self.maxLoginUsersBytes,
            fileManager: fileManager
        ) else {
            throw SteamLibraryScanError.metadataReadFailed(url, "unsafe or oversized loginusers.vdf")
        }
        guard let text = try SteamVDFFileReader.readText(url, maxBytes: Self.maxLoginUsersBytes) else {
            throw SteamLibraryScanError.metadataReadFailed(url, "loginusers.vdf was not readable")
        }
        let root = try parser.parse(text)
        guard let users = Self.value(named: "users", in: root)?.objectValue else {
            throw SteamLibraryScanError.metadataReadFailed(url, "loginusers.vdf has no users object")
        }

        let accounts = users.compactMap { key, value -> [String: VDFValue]? in
            guard Self.isNumericIdentifier(key) else { return nil }
            return value.objectValue
        }
        let remembersSignIn = accounts.contains { account in
            Self.boolValue(named: "RememberPassword", in: account) ||
                Self.boolValue(named: "AllowAutoLogin", in: account)
        }
        return (accounts.count, remembersSignIn)
    }

    private func inspectUserDataDirectories(at url: URL) throws -> Int {
        guard fileManager.fileExists(atPath: url.path) else {
            return 0
        }
        guard FileSystemItemPolicy.isNonSymlinkDirectory(url, fileManager: fileManager) else {
            throw SteamLibraryScanError.metadataReadFailed(url, "userdata root is not a safe regular directory")
        }
        let children = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var count = 0
        for child in children where Self.isNumericIdentifier(child.lastPathComponent) {
            guard FileSystemItemPolicy.isNonSymlinkDirectory(child, fileManager: fileManager) else {
                throw SteamLibraryScanError.metadataReadFailed(child, "numeric userdata entry is not a safe directory")
            }
            count += 1
        }
        return count
    }

    private func invalid(_ issue: String) -> SteamSessionInspection {
        SteamSessionInspection(
            state: .invalid,
            accountCount: 0,
            userDataDirectoryCount: 0,
            issue: issue
        )
    }

    private static func value(named name: String, in object: [String: VDFValue]) -> VDFValue? {
        object.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func boolValue(named name: String, in object: [String: VDFValue]) -> Bool {
        guard let raw = value(named: name, in: object)?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    private static func isNumericIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32 && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
}
