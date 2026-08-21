import CryptoKit
import Foundation

struct AIDiagnosticPolicyVersionsV1: Codable, Hashable, Sendable {
    let envelope = 1
    let analysis = 1
    let prompt = 1
    let outputSchema = 1
    let action = 1
    let redaction = 1

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case envelope
        case analysis
        case prompt
        case outputSchema
        case action
        case redaction
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        for key in CodingKeys.allCases {
            guard try container.decode(Int.self, forKey: key) == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "AI diagnostic policy version must be 1."
                )
            }
        }
    }
}

struct AIDiagnosticSourceBindingV1: Codable, Hashable, Sendable {
    let evidenceID: String
    let sourceLaunchRecordID: String?
    let steamAppID: String?
    let gameDisplayName: String?
    let resolvedLaunchConfigurationDigest: String?
    let trustedRecipeIdentity: String?
    let trustedRecipeDigest: String?
}

struct AIDiagnosticPlatformSnapshotV1: Codable, Hashable, Sendable {
    let appVersion: String
    let appBuild: String
    let operatingSystemVersion: String
    let runtimeVersion: String?
    let providerIdentifier: String
    let providerName: String
    let providerAvailability: String
    let processingLocationKey: String
}

enum AIDiagnosticContextBudgetModeV1: String, Codable, Hashable, Sendable {
    case conservativePublicAPIV1
    case dynamicPublicTokenCounterV1
}

struct AIDiagnosticPreviewBudgetV1: Codable, Hashable, Sendable {
    let mode: AIDiagnosticContextBudgetModeV1
    let maximumEvidenceUTF8Bytes: Int
    let maximumResponseTokens: Int
    let safetyMarginTokens: Int
    let contextSize: Int?
    let instructionTokens: Int?
    let promptTokens: Int?
    let schemaTokens: Int?
}

struct AIDiagnosticEvidenceSelectionV1: Codable, Hashable, Sendable {
    let originalUTF8ByteCount: Int
    let selectedUTF8ByteCount: Int
    let wasTruncated: Bool
    let truncationStrategy: String
    let redactionReplacementCount: Int
    let redactedEvidenceSHA256: String
}

struct AIDiagnosticUntrustedLogEvidenceV1: Codable, Hashable, Sendable {
    let type: String
    let content: String

    init(content: String) {
        self.type = "untrusted-log-evidence"
        self.content = content
    }
}

struct AIDiagnosticEvidenceEnvelopeV1: Codable, Hashable, Sendable {
    let schemaID: String
    let policyVersions: AIDiagnosticPolicyVersionsV1
    let requestCorrelationID: String
    let createdAt: String
    let languageMode: String
    let source: AIDiagnosticSourceBindingV1
    let platform: AIDiagnosticPlatformSnapshotV1
    let selection: AIDiagnosticEvidenceSelectionV1
    let previewBudget: AIDiagnosticPreviewBudgetV1
    let evidence: AIDiagnosticUntrustedLogEvidenceV1

    init(
        policyVersions: AIDiagnosticPolicyVersionsV1,
        requestCorrelationID: String,
        createdAt: String,
        languageMode: String,
        source: AIDiagnosticSourceBindingV1,
        platform: AIDiagnosticPlatformSnapshotV1,
        selection: AIDiagnosticEvidenceSelectionV1,
        previewBudget: AIDiagnosticPreviewBudgetV1,
        evidence: AIDiagnosticUntrustedLogEvidenceV1
    ) {
        self.schemaID = "com.forgeplay.ai-diagnostic-evidence-envelope.v1"
        self.policyVersions = policyVersions
        self.requestCorrelationID = requestCorrelationID
        self.createdAt = createdAt
        self.languageMode = languageMode
        self.source = source
        self.platform = platform
        self.selection = selection
        self.previewBudget = previewBudget
        self.evidence = evidence
    }
}

struct AIDiagnosticEnvelopeProjectionV1: Hashable, Sendable {
    let envelope: AIDiagnosticEvidenceEnvelopeV1
    let canonicalJSON: String
    let canonicalSHA256: String
}

struct AIDiagnosticExecutionReceiptV1: Codable, Hashable, Sendable {
    let schemaID: String
    let evidenceEnvelopeSHA256: String
    let providerIdentifier: String
    let processingBoundary = "on-device-no-tools-no-network"
    let contextBudgetMode: AIDiagnosticContextBudgetModeV1
    let contextSize: Int?
    let instructionTokens: Int?
    let promptTokens: Int?
    let schemaTokens: Int?
    let maximumResponseTokens: Int
    let safetyMarginTokens: Int
    let implicitRetryCount = 0
    let normalizedResultSHA256: String
    let proposalDisposition = "shown-unapplied"

    private enum CodingKeys: String, CodingKey {
        case schemaID
        case evidenceEnvelopeSHA256
        case providerIdentifier
        case processingBoundary
        case contextBudgetMode
        case contextSize
        case instructionTokens
        case promptTokens
        case schemaTokens
        case maximumResponseTokens
        case safetyMarginTokens
        case implicitRetryCount
        case normalizedResultSHA256
        case proposalDisposition
    }

    init(
        evidenceEnvelopeSHA256: String,
        providerIdentifier: String,
        contextBudgetMode: AIDiagnosticContextBudgetModeV1,
        contextSize: Int?,
        instructionTokens: Int?,
        promptTokens: Int?,
        schemaTokens: Int?,
        maximumResponseTokens: Int,
        safetyMarginTokens: Int,
        normalizedResultSHA256: String
    ) {
        self.schemaID = "com.forgeplay.ai-diagnostic-execution-receipt.v1"
        self.evidenceEnvelopeSHA256 = evidenceEnvelopeSHA256
        self.providerIdentifier = providerIdentifier
        self.contextBudgetMode = contextBudgetMode
        self.contextSize = contextSize
        self.instructionTokens = instructionTokens
        self.promptTokens = promptTokens
        self.schemaTokens = schemaTokens
        self.maximumResponseTokens = maximumResponseTokens
        self.safetyMarginTokens = safetyMarginTokens
        self.normalizedResultSHA256 = normalizedResultSHA256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaID = try container.decode(String.self, forKey: .schemaID)
        guard decodedSchemaID ==
                "com.forgeplay.ai-diagnostic-execution-receipt.v1" else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaID,
                in: container,
                debugDescription: "Unsupported AI diagnostic execution receipt schema."
            )
        }
        let decodedProcessingBoundary = try container.decode(
            String.self,
            forKey: .processingBoundary
        )
        guard decodedProcessingBoundary ==
                "on-device-no-tools-no-network" else {
            throw DecodingError.dataCorruptedError(
                forKey: .processingBoundary,
                in: container,
                debugDescription: "Invalid AI diagnostic processing boundary."
            )
        }
        let decodedRetryCount = try container.decode(
            Int.self,
            forKey: .implicitRetryCount
        )
        guard decodedRetryCount == 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .implicitRetryCount,
                in: container,
                debugDescription: "Implicit AI diagnostic retries are not permitted."
            )
        }
        let decodedProposalDisposition = try container.decode(
            String.self,
            forKey: .proposalDisposition
        )
        guard decodedProposalDisposition == "shown-unapplied" else {
            throw DecodingError.dataCorruptedError(
                forKey: .proposalDisposition,
                in: container,
                debugDescription: "Invalid AI diagnostic proposal disposition."
            )
        }

        schemaID = decodedSchemaID
        evidenceEnvelopeSHA256 = try container.decode(
            String.self,
            forKey: .evidenceEnvelopeSHA256
        )
        providerIdentifier = try container.decode(
            String.self,
            forKey: .providerIdentifier
        )
        contextBudgetMode = try container.decode(
            AIDiagnosticContextBudgetModeV1.self,
            forKey: .contextBudgetMode
        )
        contextSize = try container.decodeIfPresent(Int.self, forKey: .contextSize)
        instructionTokens = try container.decodeIfPresent(
            Int.self,
            forKey: .instructionTokens
        )
        promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens)
        schemaTokens = try container.decodeIfPresent(Int.self, forKey: .schemaTokens)
        maximumResponseTokens = try container.decode(
            Int.self,
            forKey: .maximumResponseTokens
        )
        safetyMarginTokens = try container.decode(
            Int.self,
            forKey: .safetyMarginTokens
        )
        normalizedResultSHA256 = try container.decode(
            String.self,
            forKey: .normalizedResultSHA256
        )
    }
}

struct LLMDiagnosticExecutionResult: Hashable, Sendable {
    let result: DiagnosticResult
    let receipt: AIDiagnosticExecutionReceiptV1
}

struct AIDiagnosticRecordMetadataV1: Hashable, Sendable {
    let evidenceEnvelopeJSON: String
    let evidenceEnvelopeSHA256: String
    let executionReceiptJSON: String
    let normalizedResultSHA256: String
    let proposalDisposition: String

    static func make(
        snapshot: LLMRequestSnapshot,
        execution: LLMDiagnosticExecutionResult
    ) throws -> AIDiagnosticRecordMetadataV1 {
        guard execution.receipt.evidenceEnvelopeSHA256 == snapshot.evidenceEnvelopeSHA256 else {
            throw AIDiagnosticEnvelopeError.receiptEnvelopeMismatch
        }
        let receiptProjection = try AIDiagnosticCanonicalJSONV1.encode(execution.receipt)
        return AIDiagnosticRecordMetadataV1(
            evidenceEnvelopeJSON: snapshot.evidenceEnvelopeJSON,
            evidenceEnvelopeSHA256: snapshot.evidenceEnvelopeSHA256,
            executionReceiptJSON: receiptProjection.json,
            normalizedResultSHA256: execution.receipt.normalizedResultSHA256,
            proposalDisposition: execution.receipt.proposalDisposition
        )
    }
}

enum AIDiagnosticEnvelopeError: LocalizedError {
    case canonicalEncodingFailed
    case canonicalUTF8Failed
    case receiptEnvelopeMismatch

    var errorDescription: String? {
        switch self {
        case .canonicalEncodingFailed:
            "AI 진단 증거 봉투를 표준 JSON으로 만들 수 없습니다."
        case .canonicalUTF8Failed:
            "AI 진단 증거 봉투를 UTF-8로 읽을 수 없습니다."
        case .receiptEnvelopeMismatch:
            "AI 진단 실행 기록이 사용자가 확인한 증거 봉투와 일치하지 않습니다."
        }
    }
}

enum AIDiagnosticCanonicalJSONV1 {
    static func encode<T: Encodable>(_ value: T) throws -> (json: String, sha256: String) {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(value)
        } catch {
            throw AIDiagnosticEnvelopeError.canonicalEncodingFailed
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw AIDiagnosticEnvelopeError.canonicalUTF8Failed
        }
        return (json, sha256Hex(data))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum AIDiagnosticEvidenceEnvelopeBuilderV1 {
    static func make(
        redactedLog: String,
        originalUTF8ByteCount: Int,
        selectedUTF8ByteCount: Int,
        redactionReplacementCount: Int,
        sourceLaunchRecordID: String? = nil,
        evidenceID: String? = nil,
        gameName: String? = nil,
        steamAppID: String? = nil,
        resolvedLaunchConfigurationDigest: String? = nil,
        trustedRecipeIdentity: String? = nil,
        trustedRecipeDigest: String? = nil,
        runtimeVersion: String? = nil,
        providerIdentifier: String,
        providerName: String,
        providerAvailability: AIDiagnosticProviderAvailability,
        processingLocationKey: String,
        language: ForgePlayLanguageMode,
        maximumEvidenceUTF8Bytes: Int,
        maximumResponseTokens: Int,
        safetyMarginTokens: Int,
        requestCorrelationID: UUID = UUID(),
        createdAt: Date = Date(),
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) throws -> AIDiagnosticEnvelopeProjectionV1 {
        let redactedDigest = AIDiagnosticCanonicalJSONV1.sha256Hex(Data(redactedLog.utf8))
        let source = AIDiagnosticSourceBindingV1(
            evidenceID: normalizedNonempty(evidenceID) ?? "evidence-\(requestCorrelationID.uuidString.lowercased())",
            sourceLaunchRecordID: normalizedNonempty(sourceLaunchRecordID),
            steamAppID: normalizedSteamAppID(steamAppID),
            gameDisplayName: normalizedNonempty(gameName),
            resolvedLaunchConfigurationDigest: normalizedDigest(resolvedLaunchConfigurationDigest),
            trustedRecipeIdentity: normalizedNonempty(trustedRecipeIdentity),
            trustedRecipeDigest: normalizedDigest(trustedRecipeDigest)
        )
        let platform = AIDiagnosticPlatformSnapshotV1(
            appVersion: normalizedNonempty(
                bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ) ?? "not-reported",
            appBuild: normalizedNonempty(
                bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ) ?? "not-reported",
            operatingSystemVersion: processInfo.operatingSystemVersionString,
            runtimeVersion: normalizedNonempty(runtimeVersion),
            providerIdentifier: providerIdentifier,
            providerName: providerName,
            providerAvailability: providerAvailability.storageValue,
            processingLocationKey: processingLocationKey
        )
        let selectedCount = max(0, selectedUTF8ByteCount)
        let originalCount = max(selectedCount, originalUTF8ByteCount)
        let selection = AIDiagnosticEvidenceSelectionV1(
            originalUTF8ByteCount: originalCount,
            selectedUTF8ByteCount: selectedCount,
            wasTruncated: selectedCount < originalCount,
            truncationStrategy: selectedCount < originalCount
                ? "head-error-context-tail-utf8-v1"
                : "none",
            redactionReplacementCount: max(0, redactionReplacementCount),
            redactedEvidenceSHA256: redactedDigest
        )
        let budget = AIDiagnosticPreviewBudgetV1(
            mode: budgetMode,
            maximumEvidenceUTF8Bytes: maximumEvidenceUTF8Bytes,
            maximumResponseTokens: maximumResponseTokens,
            safetyMarginTokens: safetyMarginTokens,
            contextSize: nil,
            instructionTokens: nil,
            promptTokens: nil,
            schemaTokens: nil
        )
        let envelope = AIDiagnosticEvidenceEnvelopeV1(
            policyVersions: AIDiagnosticPolicyVersionsV1(),
            requestCorrelationID: requestCorrelationID.uuidString.lowercased(),
            createdAt: iso8601String(from: createdAt),
            languageMode: language.rawValue,
            source: source,
            platform: platform,
            selection: selection,
            previewBudget: budget,
            evidence: AIDiagnosticUntrustedLogEvidenceV1(content: redactedLog)
        )
        let canonical = try AIDiagnosticCanonicalJSONV1.encode(envelope)
        return AIDiagnosticEnvelopeProjectionV1(
            envelope: envelope,
            canonicalJSON: canonical.json,
            canonicalSHA256: canonical.sha256
        )
    }

    private static var budgetMode: AIDiagnosticContextBudgetModeV1 {
        if #available(macOS 26.4, *) {
            return .dynamicPublicTokenCounterV1
        }
        return .conservativePublicAPIV1
    }

    private static func normalizedNonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(512))
    }

    private static func normalizedSteamAppID(_ value: String?) -> String? {
        guard let normalized = normalizedNonempty(value),
              normalized.count <= 20,
              normalized.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains) else {
            return nil
        }
        return normalized
    }

    private static func normalizedDigest(_ value: String?) -> String? {
        guard let normalized = normalizedNonempty(value)?.lowercased(),
              normalized.count == 64,
              normalized.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "0123456789abcdef").contains
              ) else {
            return nil
        }
        return normalized
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension AIDiagnosticProviderAvailability {
    var storageValue: String {
        switch self {
        case .available: "available"
        case .deviceNotEligible: "device-not-eligible"
        case .appleIntelligenceNotEnabled: "apple-intelligence-not-enabled"
        case .modelNotReady: "model-not-ready"
        }
    }
}
