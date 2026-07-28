import CryptoKit
import Foundation
import Observation

struct CompatibilityDBUpdateResult: Hashable {
    var databaseVersion: Int
    var importedCount: Int
    var updatedCount: Int
    var removedRecipeIDs: [String]
    var message: String

    var removedCount: Int {
        removedRecipeIDs.count
    }
}

struct CompatibilityDBSignedIndex: Codable, Hashable {
    var payload: CompatibilityDBIndexPayload
    var signature: String
}

struct CompatibilityDBIndexPayload: Codable, Hashable {
    var schemaVersion: Int
    var databaseVersion: Int
    var generatedAt: Date?
    var recipes: [CompatibilityDBRecipeDescriptor]
}

struct CompatibilityDBRecipeDescriptor: Codable, Hashable, Identifiable {
    var id: String
    var url: URL
    var sha256: String
    var signature: String
}

enum CompatibilityDBVersionPolicyError: LocalizedError, Equatable {
    case invalidDatabaseVersion(Int)
    case emptyAuthoritativeSnapshot
    case rollback(current: Int, received: Int)
    case versionReuseWithDifferentPayload(Int)
    case invalidStoredSnapshotMetadata(String)
    case inconsistentStoredSnapshotMetadata(Int)

    var errorDescription: String? {
        switch self {
        case .invalidDatabaseVersion(let version):
            "호환성 DB databaseVersion은 양의 정수여야 합니다: \(version)"
        case .emptyAuthoritativeSnapshot:
            "호환성 DB snapshot에는 최소 1개의 recipe가 있어야 합니다."
        case .rollback(let current, let received):
            "호환성 DB rollback을 차단했습니다: current \(current), received \(received)"
        case .versionReuseWithDifferentPayload(let version):
            "같은 호환성 DB databaseVersion에 서로 다른 signed payload를 적용할 수 없습니다: \(version)"
        case .invalidStoredSnapshotMetadata(let id):
            "저장된 호환성 DB snapshot 메타데이터가 올바르지 않습니다: \(id)"
        case .inconsistentStoredSnapshotMetadata(let version):
            "저장된 호환성 DB snapshot 메타데이터가 서로 일치하지 않습니다: \(version)"
        }
    }
}

private struct CompatibilityDBStoredSnapshotMetadata: Codable, Hashable {
    static let schemaVersion = 1

    var metadataSchemaVersion: Int
    var databaseVersion: Int
    var generatedAt: Date?
    var indexPayloadSHA256: String
}

private struct CompatibilityDBStoredSnapshotBaseline {
    var databaseVersion: Int
    var indexPayloadSHA256: String
}

enum CompatibilityDBUpdateError: LocalizedError {
    case missingFeedURL
    case insecureFeedURL
    case invalidFeedURL
    case insecureRecipeURL(String)
    case invalidRecipeDescriptor(String)
    case duplicateRecipeDescriptor(String)
    case tooManyRecipes(Int, Int)
    case insecureResolvedURL(String)
    case invalidHTTPStatus(String, Int)
    case responseTooLarge(String, Int, Int)
    case signatureVerifierMissing
    case invalidPublicKey
    case unsupportedSchemaVersion(Int)
    case invalidIndexSignature
    case invalidRecipeSignature(String)
    case checksumMismatch(String)
    case recipeIdMismatch(expected: String, actual: String)
    case invalidRecipe(String)
    case duplicateStoredRecipeRecord(String)
    case updateInProgress

    var errorDescription: String? {
        switch self {
        case .missingFeedURL:
            "호환성 DB 업데이트 주소를 먼저 입력해야 합니다."
        case .insecureFeedURL:
            "호환성 DB 업데이트는 HTTPS 주소만 사용할 수 있습니다."
        case .invalidFeedURL:
            "호환성 DB 업데이트 주소는 host가 있는 HTTPS 주소여야 하며 사용자 정보, fragment, secret query parameter를 포함할 수 없습니다."
        case .insecureRecipeURL(let id):
            "호환성 정보 파일은 HTTPS 주소만 사용할 수 있습니다: \(id)"
        case .invalidRecipeDescriptor(let id):
            "호환성 정보 descriptor가 올바르지 않습니다: \(id)"
        case .duplicateRecipeDescriptor(let id):
            "호환성 정보 descriptor ID가 중복되었습니다: \(id)"
        case .tooManyRecipes(let count, let limit):
            "호환성 DB index에 포함된 recipe가 너무 많습니다: \(count) / limit \(limit)"
        case .insecureResolvedURL(let context):
            "호환성 DB 업데이트가 공개 HTTPS 최종 주소가 아닌 곳으로 이동해 중단했습니다: \(context)"
        case .invalidHTTPStatus(let context, let statusCode):
            "호환성 DB 업데이트 서버 응답이 올바르지 않습니다: \(context) HTTP \(statusCode)"
        case .responseTooLarge(let context, let byteCount, let limit):
            "호환성 DB 업데이트 응답이 너무 큽니다: \(context) \(byteCount) bytes / limit \(limit) bytes"
        case .signatureVerifierMissing:
            "이 앱에는 원격 호환성 DB 서명 검증 키가 포함되어 있지 않아 원격 업데이트를 적용하지 않습니다."
        case .invalidPublicKey:
            "호환성 DB 서명 검증 키를 읽을 수 없습니다."
        case .unsupportedSchemaVersion(let version):
            "지원하지 않는 호환성 DB schema version입니다: \(version)"
        case .invalidIndexSignature:
            "호환성 DB index.json 서명이 올바르지 않습니다."
        case .invalidRecipeSignature(let id):
            "호환성 정보 파일 서명이 올바르지 않습니다: \(id)"
        case .checksumMismatch(let id):
            "호환성 정보 파일 무결성 검사가 실패했습니다: \(id)"
        case .recipeIdMismatch(let expected, let actual):
            "호환성 정보 파일 ID가 index와 일치하지 않습니다: expected \(expected), actual \(actual)"
        case .invalidRecipe(let id):
            "호환성 정보 파일을 해석할 수 없습니다: \(id)"
        case .duplicateStoredRecipeRecord(let id):
            "저장된 호환성 정보 ID가 중복되었습니다: \(id)"
        case .updateInProgress:
            "호환성 DB 업데이트가 이미 진행 중입니다. 완료된 뒤 다시 시도하세요."
        }
    }
}

enum CompatibilityDBSignatureVerifierConfiguration: Hashable {
    case missing
    case invalid(String)
    case trustedPublicKey(Data)

    var canApplyRemoteUpdates: Bool {
        if case .trustedPublicKey = self {
            return true
        }
        return false
    }

    var remoteUpdateUnavailableError: CompatibilityDBUpdateError? {
        switch self {
        case .trustedPublicKey:
            return nil
        case .missing:
            return .signatureVerifierMissing
        case .invalid:
            return .invalidPublicKey
        }
    }

    var diagnosticMessage: String? {
        if case .invalid(let message) = self {
            return message
        }
        return nil
    }
}

@MainActor
@Observable
final class CompatibilityDBUpdateService {
    private static let supportedSchemaVersion = 1
    private static let maxIndexBytes = 512 * 1024
    private static let maxRecipeBytes = 256 * 1024
    private static let maxRecipeDescriptors = 512
    private static let maxRecipeIDLength = 120
    private static let storedSnapshotMetadataKey = "_forgePlayCompatibilityDB"
    private static let allowedRecipeIDScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )
    private static let hexScalars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    private static let sensitiveQueryItemNames: Set<String> = [
        "apikey",
        "accesstoken",
        "refreshtoken",
        "authtoken",
        "token",
        "secret",
        "password",
        "sessionid",
        "steamloginsecure"
    ]

    private let session: URLSession
    private let signatureVerifierConfiguration: CompatibilityDBSignatureVerifierConfiguration
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private(set) var isUpdateInProgress = false

    convenience init(
        trustedPublicKeyRawRepresentation: Data? = nil,
        session: URLSession = CompatibilityDBUpdateService.defaultRemoteUpdateSession()
    ) {
        self.init(
            signatureVerifierConfiguration: trustedPublicKeyRawRepresentation.map {
                .trustedPublicKey($0)
            } ?? .missing,
            session: session
        )
    }

    init(
        signatureVerifierConfiguration: CompatibilityDBSignatureVerifierConfiguration,
        session: URLSession = CompatibilityDBUpdateService.defaultRemoteUpdateSession()
    ) {
        self.signatureVerifierConfiguration = signatureVerifierConfiguration
        self.session = session
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
    }

    var canApplyRemoteUpdates: Bool {
        signatureVerifierConfiguration.canApplyRemoteUpdates
    }

    var remoteUpdateUnavailableError: CompatibilityDBUpdateError? {
        signatureVerifierConfiguration.remoteUpdateUnavailableError
    }

    var remoteUpdateConfigurationDiagnostic: String? {
        signatureVerifierConfiguration.diagnosticMessage
    }

    nonisolated static func defaultRemoteUpdateSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    private nonisolated static func defaultRemoteUpdateSession() -> URLSession {
        URLSession(configuration: defaultRemoteUpdateSessionConfiguration())
    }

    func update(
        from feedURL: URL?,
        existingRecords: [CompatibilityRecipeRecord]
    ) async throws -> (CompatibilityDBUpdateResult, [CompatibilityRecipeRecord]) {
        guard !isUpdateInProgress else {
            throw CompatibilityDBUpdateError.updateInProgress
        }
        isUpdateInProgress = true
        defer { isUpdateInProgress = false }

        guard let feedURL else {
            throw CompatibilityDBUpdateError.missingFeedURL
        }
        if let unavailableError = remoteUpdateUnavailableError {
            throw unavailableError
        }
        let validatedFeedURL = try validateFeedURL(feedURL)
        let recordsById = try existingRecordsById(existingRecords)

        let indexData = try await fetchData(from: validatedFeedURL, context: "index.json", maxBytes: Self.maxIndexBytes)
        let signedIndex = try validateIndex(indexData)
        let payloadData = try encoder.encode(signedIndex.payload)
        let payloadSHA256 = Self.sha256Hex(payloadData)
        try validateMonotonicSnapshot(
            incomingVersion: signedIndex.payload.databaseVersion,
            incomingPayloadSHA256: payloadSHA256,
            existingRecords: existingRecords
        )

        var validatedRecipes: [CompatibilityRecipe] = []
        validatedRecipes.reserveCapacity(signedIndex.payload.recipes.count)
        for descriptor in signedIndex.payload.recipes {
            try validateRecipeDescriptor(descriptor)
            let recipeData = try await fetchData(
                from: descriptor.url,
                context: descriptor.id,
                maxBytes: Self.maxRecipeBytes
            )
            let recipe = try validateRecipe(data: recipeData, descriptor: descriptor)
            validatedRecipes.append(recipe)
        }

        let snapshotMetadata = CompatibilityDBStoredSnapshotMetadata(
            metadataSchemaVersion: CompatibilityDBStoredSnapshotMetadata.schemaVersion,
            databaseVersion: signedIndex.payload.databaseVersion,
            generatedAt: signedIndex.payload.generatedAt,
            indexPayloadSHA256: payloadSHA256
        )
        let stagedRecords = try validatedRecipes.map { recipe in
            let record = try CompatibilityRecipeRecordProjection.makeRecord(from: recipe)
            try storeSnapshotMetadata(snapshotMetadata, in: record)
            return record
        }

        var snapshotRecords: [CompatibilityRecipeRecord] = []
        snapshotRecords.reserveCapacity(stagedRecords.count)
        for stagedRecord in stagedRecords {
            if let existingRecord = recordsById[stagedRecord.recipeId] {
                CompatibilityRecipeRecordProjection.update(existingRecord, from: stagedRecord)
                snapshotRecords.append(existingRecord)
            } else {
                snapshotRecords.append(stagedRecord)
            }
        }

        let snapshotRecipeIDs = Set(stagedRecords.map(\.recipeId))
        let removedRecipeIDs = recordsById.keys
            .filter { !snapshotRecipeIDs.contains($0) }
            .sorted()
        let importedCount = snapshotRecipeIDs.filter { recordsById[$0] == nil }.count
        let updatedCount = snapshotRecipeIDs.count - importedCount

        let result = CompatibilityDBUpdateResult(
            databaseVersion: signedIndex.payload.databaseVersion,
            importedCount: importedCount,
            updatedCount: updatedCount,
            removedRecipeIDs: removedRecipeIDs,
            message: "호환성 DB 업데이트를 확인했습니다."
        )
        return (result, snapshotRecords)
    }

    private func existingRecordsById(_ records: [CompatibilityRecipeRecord]) throws -> [String: CompatibilityRecipeRecord] {
        var recordsById: [String: CompatibilityRecipeRecord] = [:]
        for record in records {
            let id = record.recipeId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard record.recipeId == id,
                  !id.isEmpty,
                  id.count <= Self.maxRecipeIDLength,
                  id.unicodeScalars.allSatisfy(Self.isAllowedRecipeIDScalar) else {
                throw CompatibilityDBUpdateError.invalidRecipeDescriptor(record.recipeId)
            }
            guard recordsById[id] == nil else {
                throw CompatibilityDBUpdateError.duplicateStoredRecipeRecord(id)
            }
            recordsById[id] = record
        }
        return recordsById
    }

    func validateIndex(_ data: Data) throws -> CompatibilityDBSignedIndex {
        guard data.count <= Self.maxIndexBytes else {
            throw CompatibilityDBUpdateError.responseTooLarge("index.json", data.count, Self.maxIndexBytes)
        }
        let signedIndex = try decoder.decode(CompatibilityDBSignedIndex.self, from: data)
        let payloadData = try encoder.encode(signedIndex.payload)
        guard try verify(signature: signedIndex.signature, data: payloadData) else {
            throw CompatibilityDBUpdateError.invalidIndexSignature
        }
        guard signedIndex.payload.schemaVersion == Self.supportedSchemaVersion else {
            throw CompatibilityDBUpdateError.unsupportedSchemaVersion(signedIndex.payload.schemaVersion)
        }
        try validateIndexPayload(signedIndex.payload)
        return signedIndex
    }

    func validateRecipeDescriptor(_ descriptor: CompatibilityDBRecipeDescriptor) throws {
        let id = descriptor.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard descriptor.id == id,
              !id.isEmpty,
              id.count <= Self.maxRecipeIDLength,
              id.unicodeScalars.allSatisfy(Self.isAllowedRecipeIDScalar) else {
            throw CompatibilityDBUpdateError.invalidRecipeDescriptor(descriptor.id)
        }
        guard descriptor.url.scheme?.lowercased() == "https" else {
            throw CompatibilityDBUpdateError.insecureRecipeURL(descriptor.id)
        }
        guard Self.isPublicHTTPSURL(descriptor.url) else {
            throw CompatibilityDBUpdateError.invalidRecipeDescriptor(descriptor.id)
        }
        let sha256 = descriptor.sha256.trimmingCharacters(in: .whitespacesAndNewlines)
        guard descriptor.sha256 == sha256,
              sha256.count == 64,
              sha256.unicodeScalars.allSatisfy(Self.isHexScalar) else {
            throw CompatibilityDBUpdateError.invalidRecipeDescriptor(descriptor.id)
        }
        guard Data(base64Encoded: descriptor.signature) != nil else {
            throw CompatibilityDBUpdateError.invalidRecipeDescriptor(descriptor.id)
        }
    }

    func validateRecipe(
        data: Data,
        descriptor: CompatibilityDBRecipeDescriptor
    ) throws -> CompatibilityRecipe {
        try validateRecipeDescriptor(descriptor)
        guard data.count <= Self.maxRecipeBytes else {
            throw CompatibilityDBUpdateError.responseTooLarge(descriptor.id, data.count, Self.maxRecipeBytes)
        }
        let digest = Self.sha256Hex(data)
        guard digest == descriptor.sha256.lowercased() else {
            throw CompatibilityDBUpdateError.checksumMismatch(descriptor.id)
        }
        guard try verify(signature: descriptor.signature, data: data) else {
            throw CompatibilityDBUpdateError.invalidRecipeSignature(descriptor.id)
        }
        do {
            let decodedRecipe = try decoder.decode(CompatibilityRecipe.self, from: data)
            guard decodedRecipe.id == descriptor.id else {
                throw CompatibilityDBUpdateError.recipeIdMismatch(expected: descriptor.id, actual: decodedRecipe.id)
            }
            guard let recipe = CompatibilityRecipePolicy.normalized(decodedRecipe) else {
                throw CompatibilityDBUpdateError.invalidRecipe(descriptor.id)
            }
            return recipe
        } catch let error as CompatibilityDBUpdateError {
            throw error
        } catch {
            throw CompatibilityDBUpdateError.invalidRecipe(descriptor.id)
        }
    }

    private func fetchData(from url: URL, context: String, maxBytes: Int) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let resolvedURL = response.url, !Self.isPublicHTTPSURL(resolvedURL) {
            throw CompatibilityDBUpdateError.insecureResolvedURL(context)
        }
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw CompatibilityDBUpdateError.invalidHTTPStatus(context, httpResponse.statusCode)
        }
        guard data.count <= maxBytes else {
            throw CompatibilityDBUpdateError.responseTooLarge(context, data.count, maxBytes)
        }
        return data
    }

    func validateFeedURL(_ url: URL?) throws -> URL {
        guard let url else {
            throw CompatibilityDBUpdateError.missingFeedURL
        }
        guard url.scheme?.lowercased() == "https" else {
            throw CompatibilityDBUpdateError.insecureFeedURL
        }
        guard Self.isPublicHTTPSURL(url) else {
            throw CompatibilityDBUpdateError.invalidFeedURL
        }
        return url
    }

    private func validateIndexPayload(_ payload: CompatibilityDBIndexPayload) throws {
        guard payload.databaseVersion > 0 else {
            throw CompatibilityDBVersionPolicyError.invalidDatabaseVersion(payload.databaseVersion)
        }
        // Schema v1 is emitted from the signer's complete recipe directory and has no
        // delta or tombstone field, so the descriptor list is an authoritative snapshot.
        guard !payload.recipes.isEmpty else {
            throw CompatibilityDBVersionPolicyError.emptyAuthoritativeSnapshot
        }
        guard payload.recipes.count <= Self.maxRecipeDescriptors else {
            throw CompatibilityDBUpdateError.tooManyRecipes(payload.recipes.count, Self.maxRecipeDescriptors)
        }

        var seenRecipeIDs = Set<String>()
        for descriptor in payload.recipes {
            try validateRecipeDescriptor(descriptor)
            guard seenRecipeIDs.insert(descriptor.id).inserted else {
                throw CompatibilityDBUpdateError.duplicateRecipeDescriptor(descriptor.id)
            }
        }
    }

    private func validateMonotonicSnapshot(
        incomingVersion: Int,
        incomingPayloadSHA256: String,
        existingRecords: [CompatibilityRecipeRecord]
    ) throws {
        guard let baseline = try storedSnapshotBaseline(in: existingRecords) else {
            return
        }
        guard incomingVersion >= baseline.databaseVersion else {
            throw CompatibilityDBVersionPolicyError.rollback(
                current: baseline.databaseVersion,
                received: incomingVersion
            )
        }
        if incomingVersion == baseline.databaseVersion,
           incomingPayloadSHA256 != baseline.indexPayloadSHA256 {
            throw CompatibilityDBVersionPolicyError.versionReuseWithDifferentPayload(incomingVersion)
        }
    }

    private func storedSnapshotBaseline(
        in records: [CompatibilityRecipeRecord]
    ) throws -> CompatibilityDBStoredSnapshotBaseline? {
        let metadata = try records.compactMap(storedSnapshotMetadata)
        guard let currentVersion = metadata.map(\.databaseVersion).max() else {
            return nil
        }
        let currentMetadata = metadata.filter { $0.databaseVersion == currentVersion }
        let payloadHashes = Set(currentMetadata.map(\.indexPayloadSHA256))
        guard payloadHashes.count == 1, let payloadHash = payloadHashes.first else {
            throw CompatibilityDBVersionPolicyError.inconsistentStoredSnapshotMetadata(currentVersion)
        }
        return CompatibilityDBStoredSnapshotBaseline(
            databaseVersion: currentVersion,
            indexPayloadSHA256: payloadHash
        )
    }

    private func storedSnapshotMetadata(
        in record: CompatibilityRecipeRecord
    ) throws -> CompatibilityDBStoredSnapshotMetadata? {
        guard let data = record.recipeJSON.data(using: .utf8),
              data.count <= Self.maxRecipeBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw CompatibilityDBVersionPolicyError.invalidStoredSnapshotMetadata(record.recipeId)
        }
        guard let metadataObject = dictionary[Self.storedSnapshotMetadataKey] else {
            return nil
        }
        guard JSONSerialization.isValidJSONObject(metadataObject),
              let metadataData = try? JSONSerialization.data(withJSONObject: metadataObject),
              let metadata = try? decoder.decode(CompatibilityDBStoredSnapshotMetadata.self, from: metadataData),
              metadata.metadataSchemaVersion == CompatibilityDBStoredSnapshotMetadata.schemaVersion,
              metadata.databaseVersion > 0,
              metadata.indexPayloadSHA256.count == 64,
              metadata.indexPayloadSHA256.unicodeScalars.allSatisfy(Self.isHexScalar) else {
            throw CompatibilityDBVersionPolicyError.invalidStoredSnapshotMetadata(record.recipeId)
        }
        return metadata
    }

    private func storeSnapshotMetadata(
        _ metadata: CompatibilityDBStoredSnapshotMetadata,
        in record: CompatibilityRecipeRecord
    ) throws {
        guard let recipeData = record.recipeJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: recipeData),
              var dictionary = object as? [String: Any],
              let metadataData = try? encoder.encode(metadata),
              let metadataObject = try? JSONSerialization.jsonObject(with: metadataData) else {
            throw CompatibilityDBVersionPolicyError.invalidStoredSnapshotMetadata(record.recipeId)
        }
        dictionary[Self.storedSnapshotMetadataKey] = metadataObject
        guard JSONSerialization.isValidJSONObject(dictionary),
              let storedData = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
              storedData.count <= Self.maxRecipeBytes,
              let storedJSON = String(data: storedData, encoding: .utf8) else {
            throw CompatibilityDBVersionPolicyError.invalidStoredSnapshotMetadata(record.recipeId)
        }
        record.recipeJSON = storedJSON
    }

    private func verify(signature: String, data: Data) throws -> Bool {
        guard case .trustedPublicKey(let trustedPublicKeyRawRepresentation) = signatureVerifierConfiguration else {
            if let error = signatureVerifierConfiguration.remoteUpdateUnavailableError {
                throw error
            }
            throw CompatibilityDBUpdateError.signatureVerifierMissing
        }
        guard let signatureData = Data(base64Encoded: signature) else {
            return false
        }
        let publicKey: P256.Signing.PublicKey
        do {
            publicKey = try P256.Signing.PublicKey(rawRepresentation: trustedPublicKeyRawRepresentation)
        } catch {
            throw CompatibilityDBUpdateError.invalidPublicKey
        }
        do {
            let ecdsaSignature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
            return publicKey.isValidSignature(ecdsaSignature, for: data)
        } catch {
            return false
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isAllowedRecipeIDScalar(_ scalar: UnicodeScalar) -> Bool {
        allowedRecipeIDScalars.contains(scalar)
    }

    private static func isHexScalar(_ scalar: UnicodeScalar) -> Bool {
        hexScalars.contains(scalar)
    }

    private static func isPublicHTTPSURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              !hasSensitiveQueryItem(components) else {
            return false
        }
        return true
    }

    private static func hasSensitiveQueryItem(_ components: URLComponents) -> Bool {
        guard let queryItems = components.queryItems else {
            return false
        }
        return queryItems.contains { item in
            let normalizedName = item.name
                .lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
            return sensitiveQueryItemNames.contains(normalizedName)
        }
    }
}
