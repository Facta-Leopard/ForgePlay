import CryptoKit
import Darwin
import Foundation

enum CompatibilityCatalogStatus: String, Codable, CaseIterable, Sendable {
    case playable
    case testing
    case blocked
    case unknown
}

enum CompatibilityCatalogSource: String, Codable, Sendable {
    case projectTest = "project-test"
    case githubIssue = "github-issue"
    case communityReport = "community-report"
}

enum CompatibilityCatalogBlocker: String, Codable, Sendable {
    case antiCheat = "anti-cheat"
    case launcher
    case graphics
    case runtime
    case securityModule = "security-module"
    case unknown
}

struct CompatibilityCatalogTestProfile: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let platform: String
    let chip: String
    let unifiedMemoryGB: Int?
    let macOSVersion: String?
    let forgePlayVersion: String?
    let runtimeVersion: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case platform
        case chip
        case unifiedMemoryGB
        case macOSVersion
        case forgePlayVersion
        case runtimeVersion
    }
}

struct CompatibilityCatalogGame: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let titles: [String: String]
    let steamAppId: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case titles
        case steamAppId
    }

    func localizedTitle(for language: ForgePlayLanguageMode) -> String {
        titles.localizedCompatibilityValue(for: language) ?? titles["en"] ?? id
    }
}

struct CompatibilityCatalogReport: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let gameId: String
    let testProfileId: String?
    let status: CompatibilityCatalogStatus
    let source: CompatibilityCatalogSource
    let reporter: String?
    let testedAt: String?
    let notes: [String: String]?
    let blocker: CompatibilityCatalogBlocker?
    let forgePlayVersion: String?
    let gameVersion: String?
    let renderer: String?
    let compatibilityOptions: [String]?

    private enum CodingKeys: String, CodingKey {
        case id
        case gameId
        case testProfileId
        case status
        case source
        case reporter
        case testedAt
        case notes
        case blocker
        case forgePlayVersion
        case gameVersion
        case renderer
        case compatibilityOptions
    }

    func localizedNote(for language: ForgePlayLanguageMode) -> String? {
        notes?.localizedCompatibilityValue(for: language)
    }
}

struct CompatibilityCatalogSnapshot: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let updatedAt: String
    let testProfiles: [CompatibilityCatalogTestProfile]
    let games: [CompatibilityCatalogGame]
    let reports: [CompatibilityCatalogReport]
    // SHA-256 of the validated JSON payload after deterministic key ordering.
    var sourcePayloadSHA256: String? = nil

    var catalogRevision: String {
        "website-v\(schemaVersion)-\(updatedAt)"
    }

    var sourceURL: String {
        "https://facta-leopard.github.io/ForgePlay/site-data/compatibility-games.json"
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case updatedAt
        case testProfiles
        case games
        case reports
    }
}

struct CompatibilityCatalogEntry: Hashable, Identifiable, Sendable {
    let report: CompatibilityCatalogReport
    let game: CompatibilityCatalogGame
    let testProfile: CompatibilityCatalogTestProfile?

    var id: String { report.id }
}

struct ValidatedCompatibilityCatalogPayload: Sendable {
    let data: Data
    let snapshot: CompatibilityCatalogSnapshot
}

enum CompatibilityCatalogServiceError: LocalizedError {
    case bundledSnapshotMissing
    case unsafeSnapshot(URL)
    case snapshotTooLarge(Int, Int)
    case snapshotDecodeFailed
    case unsupportedSchemaVersion(Int)
    case invalidUpdatedAt(String)
    case invalidIdentifier(String)
    case duplicateIdentifier(String)
    case invalidLocalizedText(String)
    case invalidTestProfile(String)
    case danglingGameReference(String)
    case danglingTestProfileReference(String)
    case countLimitExceeded(String, Int, Int)

    var errorDescription: String? {
        switch self {
        case .bundledSnapshotMissing:
            "앱에 포함된 호환성 목록을 찾을 수 없습니다."
        case .unsafeSnapshot(let url):
            "호환성 목록이 안전한 일반 파일이 아닙니다: \(url.lastPathComponent)"
        case .snapshotTooLarge(let size, let limit):
            "호환성 목록이 너무 큽니다: \(size) bytes / limit \(limit) bytes"
        case .snapshotDecodeFailed:
            "앱에 포함된 호환성 목록을 읽을 수 없습니다."
        case .unsupportedSchemaVersion(let version):
            "지원하지 않는 호환성 목록 형식입니다: \(version)"
        case .invalidUpdatedAt(let value):
            "호환성 목록 갱신 날짜가 올바르지 않습니다: \(value)"
        case .invalidIdentifier(let value):
            "호환성 목록 식별자가 올바르지 않습니다: \(value)"
        case .duplicateIdentifier(let value):
            "호환성 목록 식별자가 중복되었습니다: \(value)"
        case .invalidLocalizedText(let value):
            "호환성 목록의 다국어 텍스트가 올바르지 않습니다: \(value)"
        case .invalidTestProfile(let value):
            "호환성 목록의 테스트 환경이 올바르지 않습니다: \(value)"
        case .danglingGameReference(let value):
            "호환성 제보가 존재하지 않는 게임을 가리킵니다: \(value)"
        case .danglingTestProfileReference(let value):
            "호환성 제보가 존재하지 않는 테스트 환경을 가리킵니다: \(value)"
        case .countLimitExceeded(let collection, let count, let limit):
            "호환성 목록 항목이 제한을 넘었습니다: \(collection) \(count) / \(limit)"
        }
    }
}

struct CompatibilityCatalogService: Sendable {
    static let supportedSchemaVersions = 1...2
    static let maximumSnapshotBytes = 2 * 1024 * 1024
    static let maximumGames = 512
    static let maximumTestProfiles = 128
    static let maximumReports = 2_048

    func loadBundledSnapshot(bundle: Bundle = .main) throws -> CompatibilityCatalogSnapshot {
        let url = bundle.url(
            forResource: "compatibility-games",
            withExtension: "json",
            subdirectory: "CompatibilityCatalog"
        ) ?? bundle.url(forResource: "compatibility-games", withExtension: "json")
        guard let url else {
            throw CompatibilityCatalogServiceError.bundledSnapshotMissing
        }
        return try loadSnapshot(at: url)
    }

    func loadSnapshot(at url: URL) throws -> CompatibilityCatalogSnapshot {
        try loadValidatedPayload(at: url).snapshot
    }

    func loadValidatedPayload(at url: URL) throws -> ValidatedCompatibilityCatalogPayload {
        let data = try Self.readStableRegularFile(at: url)
        return ValidatedCompatibilityCatalogPayload(
            data: data,
            snapshot: try loadSnapshot(data: data)
        )
    }

    func loadSnapshot(data: Data) throws -> CompatibilityCatalogSnapshot {
        guard data.count <= Self.maximumSnapshotBytes else {
            throw CompatibilityCatalogServiceError.snapshotTooLarge(
                data.count,
                Self.maximumSnapshotBytes
            )
        }
        let snapshot: CompatibilityCatalogSnapshot
        let canonicalPayload: Data
        do {
            canonicalPayload = try Self.validateSchemaShape(data)
            snapshot = try JSONDecoder().decode(CompatibilityCatalogSnapshot.self, from: data)
        } catch let error as CompatibilityCatalogServiceError {
            throw error
        } catch {
            throw CompatibilityCatalogServiceError.snapshotDecodeFailed
        }
        var result = try validated(snapshot)
        result.sourcePayloadSHA256 = SHA256.hash(data: canonicalPayload)
            .map { String(format: "%02x", $0) }
            .joined()
        return result
    }

    private static func readStableRegularFile(at url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CompatibilityCatalogServiceError.unsafeSnapshot(url)
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0 else {
            throw CompatibilityCatalogServiceError.unsafeSnapshot(url)
        }
        guard before.st_size <= maximumSnapshotBytes else {
            throw CompatibilityCatalogServiceError.snapshotTooLarge(
                Int(clamping: before.st_size),
                maximumSnapshotBytes
            )
        }

        var payload = Data()
        payload.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw CompatibilityCatalogServiceError.unsafeSnapshot(url)
            }
            if bytesRead == 0 { break }
            guard payload.count <= maximumSnapshotBytes - bytesRead else {
                throw CompatibilityCatalogServiceError.snapshotTooLarge(
                    payload.count + bytesRead,
                    maximumSnapshotBytes
                )
            }
            payload.append(contentsOf: buffer.prefix(bytesRead))
        }

        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              (after.st_mode & S_IFMT) == S_IFREG,
              after.st_nlink == 1,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_mode == after.st_mode,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              payload.count == Int(after.st_size) else {
            throw CompatibilityCatalogServiceError.unsafeSnapshot(url)
        }
        return payload
    }

    private static func validateSchemaShape(_ data: Data) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CompatibilityCatalogServiceError.snapshotDecodeFailed
        }
        let topLevelKeys: Set<String> = [
            "$schema", "schemaVersion", "updatedAt", "testProfiles", "games", "reports"
        ]
        try requireExactKeys(
            root,
            allowed: topLevelKeys,
            required: ["schemaVersion", "updatedAt", "testProfiles", "games", "reports"]
        )
        if let schemaReference = root["$schema"], !(schemaReference is String) {
            throw CompatibilityCatalogServiceError.snapshotDecodeFailed
        }
        guard let schemaNumber = root["schemaVersion"] as? NSNumber,
              CFGetTypeID(schemaNumber) != CFBooleanGetTypeID(),
              schemaNumber.doubleValue == Double(schemaNumber.intValue) else {
            throw CompatibilityCatalogServiceError.snapshotDecodeFailed
        }
        let schemaVersion = schemaNumber.intValue
        guard supportedSchemaVersions.contains(schemaVersion) else {
            throw CompatibilityCatalogServiceError.unsupportedSchemaVersion(schemaVersion)
        }
        guard let profiles = root["testProfiles"] as? [[String: Any]],
              let games = root["games"] as? [[String: Any]],
              let reports = root["reports"] as? [[String: Any]] else {
            throw CompatibilityCatalogServiceError.snapshotDecodeFailed
        }

        let requiredProfileKeys: Set<String> = [
            "id", "platform", "chip", "unifiedMemoryGB", "macOSVersion"
        ]
        let profileKeys = schemaVersion == 1
            ? requiredProfileKeys
            : requiredProfileKeys.union(["forgePlayVersion", "runtimeVersion"])
        for profile in profiles {
            try requireExactKeys(
                profile,
                allowed: profileKeys,
                required: requiredProfileKeys
            )
        }
        let requiredGameKeys: Set<String> = ["id", "titles"]
        let gameKeys = schemaVersion == 1
            ? requiredGameKeys
            : requiredGameKeys.union(["steamAppId"])
        for game in games {
            try requireExactKeys(game, allowed: gameKeys, required: requiredGameKeys)
        }
        let requiredReportKeys: Set<String> = [
            "id", "gameId", "testProfileId", "status", "source", "testedAt", "notes", "blocker"
        ]
        let baseReportKeys = requiredReportKeys.union(["reporter"])
        let reportKeys = schemaVersion == 1
            ? baseReportKeys
            : baseReportKeys.union([
                "forgePlayVersion", "gameVersion", "renderer", "compatibilityOptions"
            ])
        for report in reports {
            try requireExactKeys(report, allowed: reportKeys, required: requiredReportKeys)
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func requireExactKeys(
        _ object: [String: Any],
        allowed: Set<String>,
        required: Set<String>
    ) throws {
        let keys = Set(object.keys)
        guard keys.isSubset(of: allowed), required.isSubset(of: keys) else {
            throw CompatibilityCatalogServiceError.snapshotDecodeFailed
        }
    }

    func entries(in snapshot: CompatibilityCatalogSnapshot) -> [CompatibilityCatalogEntry] {
        let games = Dictionary(uniqueKeysWithValues: snapshot.games.map { ($0.id, $0) })
        let profiles = Dictionary(uniqueKeysWithValues: snapshot.testProfiles.map { ($0.id, $0) })
        return snapshot.reports.compactMap { report in
            guard let game = games[report.gameId] else { return nil }
            return CompatibilityCatalogEntry(
                report: report,
                game: game,
                testProfile: report.testProfileId.flatMap { profiles[$0] }
            )
        }
    }

    private func validated(
        _ snapshot: CompatibilityCatalogSnapshot
    ) throws -> CompatibilityCatalogSnapshot {
        guard Self.supportedSchemaVersions.contains(snapshot.schemaVersion) else {
            throw CompatibilityCatalogServiceError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }
        guard Self.isValidFullDate(snapshot.updatedAt) else {
            throw CompatibilityCatalogServiceError.invalidUpdatedAt(snapshot.updatedAt)
        }
        try Self.requireCount(snapshot.games.count, limit: Self.maximumGames, name: "games")
        try Self.requireCount(
            snapshot.testProfiles.count,
            limit: Self.maximumTestProfiles,
            name: "testProfiles"
        )
        try Self.requireCount(snapshot.reports.count, limit: Self.maximumReports, name: "reports")

        let gameIDs = try Self.validatedUniqueIDs(snapshot.games.map(\.id))
        let profileIDs = try Self.validatedUniqueIDs(snapshot.testProfiles.map(\.id))
        _ = try Self.validatedUniqueIDs(snapshot.reports.map(\.id))

        for game in snapshot.games {
            guard let english = game.titles["en"], !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let korean = game.titles["ko"], !korean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  game.titles.values.allSatisfy(Self.isValidLocalizedText) else {
                throw CompatibilityCatalogServiceError.invalidLocalizedText(game.id)
            }
            if let steamAppID = game.steamAppId,
               steamAppID.isEmpty || steamAppID.count > 20 ||
                !steamAppID.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) {
                throw CompatibilityCatalogServiceError.invalidIdentifier(game.id)
            }
        }
        for profile in snapshot.testProfiles {
            guard Self.isValidLocalizedText(profile.platform),
                  Self.isValidLocalizedText(profile.chip),
                  profile.unifiedMemoryGB.map({ $0 > 0 }) ?? true,
                  profile.macOSVersion.map(Self.isValidLocalizedText) ?? true,
                  profile.forgePlayVersion.map(Self.isValidLocalizedText) ?? true,
                  profile.runtimeVersion.map(Self.isValidLocalizedText) ?? true else {
                throw CompatibilityCatalogServiceError.invalidTestProfile(profile.id)
            }
        }
        for report in snapshot.reports {
            guard gameIDs.contains(report.gameId) else {
                throw CompatibilityCatalogServiceError.danglingGameReference(report.gameId)
            }
            if let profileID = report.testProfileId, !profileIDs.contains(profileID) {
                throw CompatibilityCatalogServiceError.danglingTestProfileReference(profileID)
            }
            if let testedAt = report.testedAt, !Self.isValidFullDate(testedAt) {
                throw CompatibilityCatalogServiceError.invalidUpdatedAt(testedAt)
            }
            if let reporter = report.reporter, !Self.isValidLocalizedText(reporter) {
                throw CompatibilityCatalogServiceError.invalidLocalizedText(report.id)
            }
            if let forgePlayVersion = report.forgePlayVersion,
               !Self.isValidLocalizedText(forgePlayVersion) {
                throw CompatibilityCatalogServiceError.invalidLocalizedText(report.id)
            }
            if let gameVersion = report.gameVersion,
               !Self.isValidLocalizedText(gameVersion) {
                throw CompatibilityCatalogServiceError.invalidLocalizedText(report.id)
            }
            if let notes = report.notes,
               notes.isEmpty || !notes.values.allSatisfy(Self.isValidLocalizedText) {
                throw CompatibilityCatalogServiceError.invalidLocalizedText(report.id)
            }
            if let renderer = report.renderer, !Self.isValidLocalizedText(renderer) {
                throw CompatibilityCatalogServiceError.invalidLocalizedText(report.id)
            }
            if let compatibilityOptions = report.compatibilityOptions,
               compatibilityOptions.isEmpty || compatibilityOptions.count > 32 ||
                !compatibilityOptions.allSatisfy(Self.isValidLocalizedText) {
                throw CompatibilityCatalogServiceError.invalidLocalizedText(report.id)
            }
        }
        return snapshot
    }

    private static func requireCount(_ count: Int, limit: Int, name: String) throws {
        guard count <= limit else {
            throw CompatibilityCatalogServiceError.countLimitExceeded(name, count, limit)
        }
    }

    private static func validatedUniqueIDs(_ values: [String]) throws -> Set<String> {
        var result = Set<String>()
        for value in values {
            guard isValidIdentifier(value) else {
                throw CompatibilityCatalogServiceError.invalidIdentifier(value)
            }
            guard result.insert(value).inserted else {
                throw CompatibilityCatalogServiceError.duplicateIdentifier(value)
            }
        }
        return result
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 160 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard value.unicodeScalars.allSatisfy(allowed.contains),
              value.first != "-",
              value.last != "-",
              !value.contains("--") else {
            return false
        }
        return true
    }

    private static func isValidLocalizedText(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty &&
            trimmed.count <= 4_000 &&
            !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isValidFullDate(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0].count == 4,
              components[1].count == 2,
              components[2].count == 2,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return false }
        calendar.timeZone = utc
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let normalized = calendar.dateComponents([.year, .month, .day], from: date)
        return normalized.year == year && normalized.month == month && normalized.day == day
    }
}

private extension Dictionary where Key == String, Value == String {
    func localizedCompatibilityValue(for language: ForgePlayLanguageMode) -> String? {
        let resolvedLanguage = language == .system
            ? ForgePlaySystemLanguageResolver.resolvedLanguageMode()
            : language
        let preferredKey = resolvedLanguage.localeIdentifier ?? "en"
        let candidates = [preferredKey, preferredKey.split(separator: "-").first.map(String.init), "en", "ko"]
            .compactMap { $0 }
        for key in candidates {
            if let value = self[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
