import Foundation

enum SteamGameIdentityError: LocalizedError, Equatable {
    case invalidGameIdentity(SteamGame)

    var errorDescription: String? {
        switch self {
        case .invalidGameIdentity(let game):
            "Steam 게임 식별 정보가 올바르지 않습니다: \(game.steamAppId) / \(game.name)"
        }
    }
}

enum SteamGameIdentityPolicy {
    private static let maxAppIdLength = 64
    private static let maxNameLength = 160
    private static let maxInstallDirLength = 160

    nonisolated static func normalizedGame(_ game: SteamGame) -> SteamGame? {
        guard let appId = appId(game.steamAppId),
              let name = displayName(game.name),
              let installDir = installDirectoryName(game.installDir) else {
            return nil
        }
        var normalized = game
        normalized.steamAppId = appId
        normalized.name = name
        normalized.installDir = installDir
        normalized.sizeOnDisk = max(0, game.sizeOnDisk)
        return normalized
    }

    nonisolated static func appId(_ raw: String?) -> String? {
        guard let trimmed = trimmed(raw, maxLength: maxAppIdLength),
              trimmed.unicodeScalars.allSatisfy(isSafeAppIdScalar),
              trimmed.unicodeScalars.contains(where: isASCIIAlphanumeric) else {
            return nil
        }
        return trimmed
    }

    nonisolated static func displayName(_ raw: String?) -> String? {
        guard let trimmed = trimmed(raw, maxLength: maxNameLength),
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return trimmed
    }

    nonisolated static func installDirectoryName(_ raw: String?) -> String? {
        guard let trimmed = trimmed(raw, maxLength: maxInstallDirLength),
              trimmed != ".",
              trimmed != "..",
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
              !trimmed.contains("/"),
              !trimmed.contains("\\") else {
            return nil
        }
        return trimmed
    }

    nonisolated static func manifestFileNameMatches(_ url: URL, appId: String) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("appmanifest_") else {
            return false
        }
        return String(name.dropFirst("appmanifest_".count)) == appId
    }

    private nonisolated static func trimmed(_ raw: String?, maxLength: Int) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else {
            return nil
        }
        return trimmed
    }

    private nonisolated static func isSafeAppIdScalar(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIAlphanumeric(scalar) || scalar == "-"
    }

    private nonisolated static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }
}
