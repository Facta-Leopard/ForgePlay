import Foundation

struct CompatibilityRecipe: Codable, Hashable, Identifiable {
    var id: String
    var steamAppId: String?
    var name: String
    var supportStatus: String
    var beginnerSummary: String
    var technicalSummary: String
    var confidence: Double
    var requiredRuntimes: [RuntimeId]
    var launchOptions: [String]
    var notes: [String]
    var lastVerifiedAt: Date?
    var preferredGraphicsBackend: SteamRendererPolicyPreference? = nil
}

enum CompatibilityServiceError: LocalizedError {
    case decodeFailed(URL)
    case unsafeRecipeFile(URL)
    case recipeTooLarge(URL, Int, Int)
    case invalidRecipe(URL)
    case recipeDiscoveryFailed(URL, Error)
    case recipeMetadataReadFailed(URL, Error)
    case storedRecipeInvalidUTF8(String)
    case storedRecipeTooLarge(String, Int, Int)
    case storedRecipeDecodeFailed(String)
    case storedRecipeInvalid(String)
    case storedRecipeRecordMismatch(String)
    case ambiguousSteamAppID(String)

    var errorDescription: String? {
        switch self {
        case .decodeFailed(let url):
            "호환성 정보를 읽을 수 없습니다: \(url.lastPathComponent)"
        case .unsafeRecipeFile(let url):
            "호환성 정보 파일은 symlink/hardlink가 아닌 일반 파일이어야 합니다: \(url.lastPathComponent)"
        case .recipeTooLarge(let url, let byteCount, let limit):
            "호환성 정보 파일이 너무 큽니다: \(url.lastPathComponent) \(byteCount) bytes / limit \(limit) bytes"
        case .invalidRecipe(let url):
            "호환성 정보 내용이 제품 정책에 맞지 않습니다: \(url.lastPathComponent)"
        case .recipeDiscoveryFailed(let url, let error):
            "호환성 정보 파일 목록을 검사하지 못했습니다: \(url.path). \(forgePlayTechnicalErrorSummary(error))"
        case .recipeMetadataReadFailed(let url, let error):
            "호환성 정보 파일 정보를 읽지 못했습니다: \(url.path). \(forgePlayTechnicalErrorSummary(error))"
        case .storedRecipeInvalidUTF8(let id):
            "저장된 호환성 정보 JSON을 UTF-8로 읽지 못했습니다: \(id)"
        case .storedRecipeTooLarge(let id, let byteCount, let limit):
            "저장된 호환성 정보가 너무 큽니다: \(id) \(byteCount) bytes / limit \(limit) bytes"
        case .storedRecipeDecodeFailed(let id):
            "저장된 호환성 정보를 읽지 못했습니다: \(id)"
        case .storedRecipeInvalid(let id):
            "저장된 호환성 정보 내용이 제품 정책에 맞지 않습니다: \(id)"
        case .storedRecipeRecordMismatch(let id):
            "저장된 호환성 정보가 저장 레코드와 일치하지 않습니다: \(id)"
        case .ambiguousSteamAppID(let steamAppID):
            "같은 Steam App ID에 여러 호환성 정보가 있어 임의로 선택하지 않았습니다: \(steamAppID)"
        }
    }
}

enum CompatibilityRecipeRecordProjectionError: LocalizedError {
    case encodeFailed(String)
    case utf8ConversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .encodeFailed(let recipeId):
            "호환성 정보를 저장 가능한 JSON으로 변환할 수 없습니다: \(recipeId)"
        case .utf8ConversionFailed(let recipeId):
            "호환성 정보 JSON을 UTF-8 문자열로 변환할 수 없습니다: \(recipeId)"
        }
    }
}

enum CompatibilityRecipePolicy {
    private static let maxRecipeIDLength = 120
    private static let maxSteamAppIDLength = 20
    private static let maxNameLength = 160
    private static let maxSummaryLength = 1_200
    private static let maxTechnicalSummaryLength = 2_000
    private static let maxNotes = 20
    private static let maxNoteLength = 800
    private static let maxListItems = 32
    private static let allowedRecipeIDScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )
    private static let decimalDigits = CharacterSet(charactersIn: "0123456789")
    private static let allowedSupportStatuses = Set(CompatibilitySupportStatus.allCases.map(\.rawValue))

    static func normalized(_ recipe: CompatibilityRecipe) -> CompatibilityRecipe? {
        guard let id = normalizedRecipeID(recipe.id),
              let steamAppId = normalizedSteamAppID(recipe.steamAppId),
              let name = normalizedText(recipe.name, maxLength: maxNameLength),
              let beginnerSummary = normalizedText(recipe.beginnerSummary, maxLength: maxSummaryLength),
              let technicalSummary = normalizedText(recipe.technicalSummary, maxLength: maxTechnicalSummaryLength),
              recipe.confidence.isFinite,
              (0...1).contains(recipe.confidence) else {
            return nil
        }

        let supportStatus = recipe.supportStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard allowedSupportStatuses.contains(supportStatus) else {
            return nil
        }

        let requiredRuntimes = deduplicated(recipe.requiredRuntimes)
        guard requiredRuntimes.count <= maxListItems else {
            return nil
        }

        var launchOptions: [String] = []
        var seenLaunchOptions = Set<String>()
        for option in recipe.launchOptions {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let normalized = LLMRecommendedActionPolicy.normalizedLaunchOption(trimmed) else {
                return nil
            }
            if seenLaunchOptions.insert(normalized).inserted {
                launchOptions.append(normalized)
            }
        }
        guard launchOptions.count <= maxListItems else {
            return nil
        }

        var notes: [String] = []
        var seenNotes = Set<String>()
        for note in recipe.notes {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let normalized = normalizedText(trimmed, maxLength: maxNoteLength) else {
                return nil
            }
            if seenNotes.insert(normalized).inserted {
                notes.append(normalized)
            }
        }
        guard notes.count <= maxNotes else {
            return nil
        }

        return CompatibilityRecipe(
            id: id,
            steamAppId: steamAppId,
            name: name,
            supportStatus: supportStatus,
            beginnerSummary: beginnerSummary,
            technicalSummary: technicalSummary,
            confidence: recipe.confidence,
            requiredRuntimes: requiredRuntimes,
            launchOptions: launchOptions,
            notes: notes,
            lastVerifiedAt: recipe.lastVerifiedAt,
            preferredGraphicsBackend: recipe.preferredGraphicsBackend
        )
    }

    private static func normalizedRecipeID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maxRecipeIDLength,
              trimmed.unicodeScalars.allSatisfy({ allowedRecipeIDScalars.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    private static func normalizedSteamAppID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maxSteamAppIDLength,
              trimmed.unicodeScalars.allSatisfy({ decimalDigits.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    private static func normalizedText(_ value: String, maxLength: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maxLength,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    private static func deduplicated<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        var result: [T] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}

enum CompatibilityRecipeRecordProjection {
    static func makeDetachedRecord(from record: CompatibilityRecipeRecord) -> CompatibilityRecipeRecord {
        CompatibilityRecipeRecord(
            recipeId: record.recipeId,
            steamAppId: record.steamAppId,
            name: record.name,
            supportStatus: record.supportStatus,
            confidence: record.confidence,
            recipeJSON: record.recipeJSON,
            lastVerifiedAt: record.lastVerifiedAt
        )
    }

    static func makeRecord(from recipe: CompatibilityRecipe) throws -> CompatibilityRecipeRecord {
        CompatibilityRecipeRecord(
            recipeId: recipe.id,
            steamAppId: recipe.steamAppId,
            name: recipe.name,
            supportStatus: recipe.supportStatus,
            confidence: recipe.confidence,
            recipeJSON: try recipeJSON(for: recipe),
            lastVerifiedAt: recipe.lastVerifiedAt
        )
    }

    static func update(_ record: CompatibilityRecipeRecord, from recipe: CompatibilityRecipe) throws {
        let json = try recipeJSON(for: recipe)
        record.steamAppId = recipe.steamAppId
        record.name = recipe.name
        record.supportStatus = recipe.supportStatus
        record.confidence = recipe.confidence
        record.recipeJSON = json
        record.lastVerifiedAt = recipe.lastVerifiedAt
    }

    static func update(_ record: CompatibilityRecipeRecord, from source: CompatibilityRecipeRecord) {
        record.steamAppId = source.steamAppId
        record.name = source.name
        record.supportStatus = source.supportStatus
        record.confidence = source.confidence
        record.recipeJSON = source.recipeJSON
        record.lastVerifiedAt = source.lastVerifiedAt
    }

    static func recipeJSON(for recipe: CompatibilityRecipe) throws -> String {
        let data: Data
        do {
            data = try JSONEncoder.compatibilityEncoder.encode(recipe)
        } catch {
            throw CompatibilityRecipeRecordProjectionError.encodeFailed(recipe.id)
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw CompatibilityRecipeRecordProjectionError.utf8ConversionFailed(recipe.id)
        }
        return json
    }
}

struct CompatibilityService {
    private static let maxRecipeBytes = 256 * 1024
    private let decoder: JSONDecoder

    init() {
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadBundledRecipes(bundle: Bundle = .main) throws -> [CompatibilityRecipe] {
        try loadRecipes(at: recipeURLs(in: bundle))
    }

    func requiredRecipe(for game: SteamGame, bundle: Bundle = .main) throws -> CompatibilityRecipe? {
        let matches = try loadBundledRecipes(bundle: bundle).filter {
            $0.steamAppId == game.steamAppId
        }
        guard matches.count <= 1 else {
            throw CompatibilityServiceError.ambiguousSteamAppID(game.steamAppId)
        }
        return matches.first
    }

    func requiredRecipe(
        for game: SteamGame,
        records: [CompatibilityRecipeRecord],
        bundle: Bundle = .main
    ) throws -> CompatibilityRecipe? {
        let matchingRecords = records.filter {
            $0.steamAppId?.trimmingCharacters(in: .whitespacesAndNewlines) ==
                game.steamAppId
        }
        guard matchingRecords.count <= 1 else {
            throw CompatibilityServiceError.ambiguousSteamAppID(game.steamAppId)
        }
        if let matchingRecord = matchingRecords.first {
            return try requiredDecodedRecipe(matchingRecord)
        }
        return try requiredRecipe(for: game, bundle: bundle)
    }

    /// Resolves schema-validated stored data first and bundled data second for
    /// read-only diagnostic guidance. Signature verification remains owned by
    /// the update service before storage; this boundary deliberately returns
    /// data only and never mutates a prefix, launch configuration, or process
    /// policy.
    func diagnosticGuidanceRecipe(
        for game: SteamGame,
        storedRecords: [CompatibilityRecipeRecord],
        bundle: Bundle = .main
    ) throws -> CompatibilityRecipe? {
        try requiredRecipe(for: game, records: storedRecords, bundle: bundle)
    }

    func importBundledRecipes(into records: [CompatibilityRecipeRecord], bundle: Bundle = .main) throws -> [CompatibilityRecipeRecord] {
        let existing = Set(records.map(\.recipeId))
        return try loadBundledRecipes(bundle: bundle)
            .filter { !existing.contains($0.id) }
            .map { recipe in
                try CompatibilityRecipeRecordProjection.makeRecord(from: recipe)
            }
    }

    func decode(_ record: CompatibilityRecipeRecord) -> CompatibilityRecipe? {
        do {
            return try requiredDecodedRecipe(record)
        } catch {
            return nil
        }
    }

    func requiredDecodedRecipe(_ record: CompatibilityRecipeRecord) throws -> CompatibilityRecipe {
        let recordId = normalizedRecordID(record.recipeId)
        guard let data = record.recipeJSON.data(using: .utf8) else {
            throw CompatibilityServiceError.storedRecipeInvalidUTF8(recordId)
        }
        guard data.count <= Self.maxRecipeBytes else {
            throw CompatibilityServiceError.storedRecipeTooLarge(recordId, data.count, Self.maxRecipeBytes)
        }
        let decodedRecipe: CompatibilityRecipe
        do {
            decodedRecipe = try decoder.decode(CompatibilityRecipe.self, from: data)
        } catch {
            throw CompatibilityServiceError.storedRecipeDecodeFailed(recordId)
        }
        guard let recipe = CompatibilityRecipePolicy.normalized(decodedRecipe) else {
            throw CompatibilityServiceError.storedRecipeInvalid(recordId)
        }
        guard isRecipe(recipe, consistentWith: record) else {
            throw CompatibilityServiceError.storedRecipeRecordMismatch(recordId)
        }
        return recipe
    }

    func loadRecipes(at urls: [URL]) throws -> [CompatibilityRecipe] {
        var recipes: [CompatibilityRecipe] = []
        var seenRecipeIds = Set<String>()
        for url in urls {
            let recipe = try loadRecipe(at: url)
            let recipeId = recipe.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !recipeId.isEmpty, seenRecipeIds.insert(recipeId).inserted else { continue }
            recipes.append(recipe)
        }
        return recipes
    }

    func loadRecipe(at url: URL) throws -> CompatibilityRecipe {
        if !FileSystemItemPolicy.isRegularNonSymlinkFile(url) {
            do {
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(url)
            } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
                throw CompatibilityServiceError.recipeMetadataReadFailed(
                    url,
                    FileSystemItemPolicyError.metadataReadFailed(url, message)
                )
            } catch {
                throw CompatibilityServiceError.unsafeRecipeFile(url)
            }
        }
        let fileSize: Int
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize else {
                throw CompatibilityServiceError.recipeMetadataReadFailed(url, CocoaError(.fileReadUnknown))
            }
            fileSize = size
        } catch let error as CompatibilityServiceError {
            throw error
        } catch {
            throw CompatibilityServiceError.recipeMetadataReadFailed(url, error)
        }
        guard fileSize <= Self.maxRecipeBytes else {
            throw CompatibilityServiceError.recipeTooLarge(url, fileSize, Self.maxRecipeBytes)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maxRecipeBytes else {
            throw CompatibilityServiceError.recipeTooLarge(url, data.count, Self.maxRecipeBytes)
        }
        do {
            let recipe = try decoder.decode(CompatibilityRecipe.self, from: data)
            guard let normalizedRecipe = CompatibilityRecipePolicy.normalized(recipe) else {
                throw CompatibilityServiceError.invalidRecipe(url)
            }
            return normalizedRecipe
        } catch let error as CompatibilityServiceError {
            throw error
        } catch {
            throw CompatibilityServiceError.decodeFailed(url)
        }
    }

    private func recipeURLs(in bundle: Bundle) throws -> [URL] {
        var urls = Set<URL>()
        for subdirectory in ["CompatibilityDB/recipes", "recipes"] {
            for url in bundle.urls(forResourcesWithExtension: "json", subdirectory: subdirectory) ?? [] {
                urls.insert(url)
            }
        }
        for url in bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [] where isRecipeFileURL(url) {
            urls.insert(url)
        }
        if let resourceURL = bundle.resourceURL {
            urls.formUnion(try recipeURLs(inResourceRoot: resourceURL))
        }
        return urls.sorted { $0.path < $1.path }
    }

    func recipeURLs(inResourceRoot resourceURL: URL, fileManager: FileManager = .default) throws -> [URL] {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: resourceURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CompatibilityServiceError.recipeDiscoveryFailed(resourceURL, CocoaError(.fileReadUnknown))
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            } catch {
                throw CompatibilityServiceError.recipeMetadataReadFailed(url, error)
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true,
                  isRecipeFileURL(url) else {
                continue
            }
            urls.append(url)
        }
        if let enumerationError {
            throw CompatibilityServiceError.recipeDiscoveryFailed(resourceURL, enumerationError)
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func isRecipeFileURL(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "json" else { return false }
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent == "recipes" {
            return true
        }
        return url.deletingPathExtension().lastPathComponent.hasPrefix("steam-")
    }

    private func isRecipe(_ recipe: CompatibilityRecipe, consistentWith record: CompatibilityRecipeRecord) -> Bool {
        let recordRecipeId = record.recipeId.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipeId = recipe.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recordRecipeId.isEmpty, recipeId == recordRecipeId else {
            return false
        }

        let recordSteamAppId = record.steamAppId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let recordSteamAppId, !recordSteamAppId.isEmpty {
            let recipeSteamAppId = recipe.steamAppId?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard recipeSteamAppId == recordSteamAppId else {
                return false
            }
        }

        return true
    }

    private func normalizedRecordID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "<unknown>" : trimmed
    }
}

extension JSONEncoder {
    static var compatibilityEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
