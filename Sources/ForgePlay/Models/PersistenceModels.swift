import Foundation
import SwiftData

extension ModelContext {
    func saveOrRollback() throws {
        do {
            try save()
        } catch {
            rollback()
            throw error
        }
    }
}

enum AppLanguageModeOverrideSource: String {
    case userSettings
}

enum GameInputProtectionPreferenceSchema {
    /// The only destructive migration: old beta defaults become explicit opt-in.
    static let optInMigrationVersion = 1
    static let currentVersion = 1
}

@Model
final class AppSettingsRecord {
    @Attribute(.unique) var id: String
    var selectedRootPath: String?
    var selectedRootBookmark: Data?
    var managedStorageLayoutVersion: Int?
    var legacyManagedRootPath: String?
    var managedStorageMigrationCompletedAt: Date?
    // Legacy persisted columns retained only for SwiftData schema compatibility.
    // Current code clears them and derives the immutable ForgePlay Runtime from
    // the active app bundle; they must never become a selection or bookmark.
    var gptkExecutablePath: String?
    var gptkExecutableBookmark: Data?
    var lastSteamInstallerPath: String?
    var lastSteamInstallerBookmark: Data?
    var themeMode: String
    var languageMode: String?
    var isLanguageModeOverrideEnabled: Bool?
    var languageModeOverrideSource: String?
    var isAdvancedModeEnabled: Bool
    var isLLMDiagnosticsEnabled: Bool
    var llmProvider: String
    var llmBaseURL: String
    var llmModel: String
    var compatibilityDBUpdateURL: String?
    var lastCompatibilityDBUpdateAt: Date?
    var lastCompatibilityDBUpdateStatus: String?
    var lastCompatibilityDBUpdateStatusKind: String?
    var lastCompatibilityDBUpdateImportedCount: Int?
    var lastCompatibilityDBUpdateUpdatedCount: Int?
    var isLogAutoCleanupEnabled: Bool?
    var logRetentionDays: Int?
    var launchLogLimit: Int?
    var steamGraphicsBackendSelection: String?
    var wineSynchronizationSelection: String?
    var steamVideoMemorySelection: String?
    var isGameInputModifierMappingEnabled: Bool?
    var gameInputCommandBinding: String?
    var gameInputOptionBinding: String?
    var gameInputControlBinding: String?
    var blocksGameAppWindowManagementShortcuts: Bool?
    var blocksGameAppSwitchingShortcuts: Bool?
    var blocksGameMissionControlSpaceShortcuts: Bool?
    var blocksGameScreenshotShortcuts: Bool?
    var hidesPointerWhileManagedGameFrontmost: Bool?
    var gameInputProtectionPreferenceVersion: Int?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = "default",
        selectedRootPath: String? = nil,
        selectedRootBookmark: Data? = nil,
        managedStorageLayoutVersion: Int? = nil,
        legacyManagedRootPath: String? = nil,
        managedStorageMigrationCompletedAt: Date? = nil,
        gptkExecutablePath: String? = nil,
        gptkExecutableBookmark: Data? = nil,
        lastSteamInstallerPath: String? = nil,
        lastSteamInstallerBookmark: Data? = nil,
        themeMode: String = ForgePlayThemeMode.system.rawValue,
        languageMode: String? = ForgePlayLanguageMode.system.rawValue,
        isLanguageModeOverrideEnabled: Bool = false,
        languageModeOverrideSource: String? = nil,
        isAdvancedModeEnabled: Bool = false,
        isLLMDiagnosticsEnabled: Bool = false,
        llmProvider: String = AIDiagnosticProviderConfiguration.identifier,
        llmBaseURL: String = "",
        llmModel: String = AIDiagnosticProviderConfiguration.displayName,
        compatibilityDBUpdateURL: String = "",
        lastCompatibilityDBUpdateAt: Date? = nil,
        lastCompatibilityDBUpdateStatus: String = "호환성 DB 업데이트를 아직 실행하지 않았습니다.",
        lastCompatibilityDBUpdateStatusKind: String? = nil,
        lastCompatibilityDBUpdateImportedCount: Int? = nil,
        lastCompatibilityDBUpdateUpdatedCount: Int? = nil,
        isLogAutoCleanupEnabled: Bool = true,
        logRetentionDays: Int = 30,
        launchLogLimit: Int = 20,
        steamGraphicsBackendSelection: String? = nil,
        wineSynchronizationSelection: String? = nil,
        steamVideoMemorySelection: String? = nil,
        isGameInputModifierMappingEnabled: Bool? = false,
        gameInputCommandBinding: String? = GameInputModifierBinding.control.rawValue,
        gameInputOptionBinding: String? = GameInputModifierBinding.alt.rawValue,
        gameInputControlBinding: String? = GameInputModifierBinding.control.rawValue,
        blocksGameAppWindowManagementShortcuts: Bool? = false,
        blocksGameAppSwitchingShortcuts: Bool? = false,
        blocksGameMissionControlSpaceShortcuts: Bool? = false,
        blocksGameScreenshotShortcuts: Bool? = false,
        hidesPointerWhileManagedGameFrontmost: Bool? = true,
        gameInputProtectionPreferenceVersion: Int? =
            GameInputProtectionPreferenceSchema.currentVersion,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.selectedRootPath = selectedRootPath
        self.selectedRootBookmark = selectedRootBookmark
        self.managedStorageLayoutVersion = managedStorageLayoutVersion
        self.legacyManagedRootPath = legacyManagedRootPath
        self.managedStorageMigrationCompletedAt = managedStorageMigrationCompletedAt
        self.gptkExecutablePath = gptkExecutablePath
        self.gptkExecutableBookmark = gptkExecutableBookmark
        self.lastSteamInstallerPath = lastSteamInstallerPath
        self.lastSteamInstallerBookmark = lastSteamInstallerBookmark
        self.themeMode = themeMode
        self.languageMode = languageMode
        self.isLanguageModeOverrideEnabled = isLanguageModeOverrideEnabled
        self.languageModeOverrideSource = languageModeOverrideSource
        self.isAdvancedModeEnabled = isAdvancedModeEnabled
        self.isLLMDiagnosticsEnabled = isLLMDiagnosticsEnabled
        self.llmProvider = llmProvider
        self.llmBaseURL = llmBaseURL
        self.llmModel = llmModel
        self.compatibilityDBUpdateURL = compatibilityDBUpdateURL
        self.lastCompatibilityDBUpdateAt = lastCompatibilityDBUpdateAt
        self.lastCompatibilityDBUpdateStatus = lastCompatibilityDBUpdateStatus
        self.lastCompatibilityDBUpdateStatusKind = lastCompatibilityDBUpdateStatusKind
        self.lastCompatibilityDBUpdateImportedCount = lastCompatibilityDBUpdateImportedCount
        self.lastCompatibilityDBUpdateUpdatedCount = lastCompatibilityDBUpdateUpdatedCount
        self.isLogAutoCleanupEnabled = isLogAutoCleanupEnabled
        self.logRetentionDays = logRetentionDays
        self.launchLogLimit = launchLogLimit
        self.steamGraphicsBackendSelection = steamGraphicsBackendSelection
        self.wineSynchronizationSelection = wineSynchronizationSelection
        self.steamVideoMemorySelection = steamVideoMemorySelection
        self.isGameInputModifierMappingEnabled = isGameInputModifierMappingEnabled
        self.gameInputCommandBinding = gameInputCommandBinding
        self.gameInputOptionBinding = gameInputOptionBinding
        self.gameInputControlBinding = gameInputControlBinding
        self.blocksGameAppWindowManagementShortcuts =
            blocksGameAppWindowManagementShortcuts
        self.blocksGameAppSwitchingShortcuts = blocksGameAppSwitchingShortcuts
        self.blocksGameMissionControlSpaceShortcuts = blocksGameMissionControlSpaceShortcuts
        self.blocksGameScreenshotShortcuts = blocksGameScreenshotShortcuts
        self.hidesPointerWhileManagedGameFrontmost =
            hidesPointerWhileManagedGameFrontmost
        self.gameInputProtectionPreferenceVersion =
            gameInputProtectionPreferenceVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum CompatibilityDBUpdateStatusKind: String, Codable, CaseIterable {
    case notStarted
    case succeeded
    case failed
}

extension AppSettingsRecord {
    @discardableResult
    func normalizeAIDiagnosticProviderConfiguration(now: Date = Date()) -> Bool {
        var changed = false
        if llmProvider != AIDiagnosticProviderConfiguration.identifier {
            llmProvider = AIDiagnosticProviderConfiguration.identifier
            changed = true
        }
        if llmBaseURL != "" {
            llmBaseURL = ""
            changed = true
        }
        if llmModel != AIDiagnosticProviderConfiguration.displayName {
            llmModel = AIDiagnosticProviderConfiguration.displayName
            changed = true
        }
        if changed {
            updatedAt = now
        }
        return changed
    }
}

enum SteamLaunchConfigurationPersistenceError: LocalizedError, Equatable {
    case contextHasPendingChanges
    case unexpectedMode(expected: SteamLaunchMode, actual: SteamLaunchMode)
    case recordIdentityMismatch(String)
    case schemaVersionMismatch(stored: Int, decoded: Int)
    case digestMismatch
    case duplicateRecord(type: String, id: String)
    case invalidPersistenceRevision(UUID)
    case writeConflict(type: String, id: String)
    case incompleteLaunchRecordProjection
    case requestedTransactionCannotBeRecorded
    case transactionConfigurationMismatch

    var errorDescription: String? {
        switch self {
        case .contextHasPendingChanges:
            "Steam 실행 구성 저장에는 보류 중인 변경이 없는 전용 ModelContext가 필요합니다."
        case .unexpectedMode(let expected, let actual):
            "Steam 실행 구성 모드가 일치하지 않습니다: expected=\(expected.rawValue), actual=\(actual.rawValue)"
        case .recordIdentityMismatch(let reason):
            "Steam 실행 구성 저장 식별자가 일치하지 않습니다: \(reason)"
        case .schemaVersionMismatch(let stored, let decoded):
            "Steam 실행 구성 저장 버전이 일치하지 않습니다: stored=\(stored), decoded=\(decoded)"
        case .digestMismatch:
            "Steam 실행 구성 저장 다이제스트가 일치하지 않습니다."
        case .duplicateRecord(let type, let id):
            "중복된 Steam 실행 구성 저장 레코드가 있습니다: \(type)=\(id)"
        case .invalidPersistenceRevision(let revision):
            "Steam 실행 구성 저장 리비전이 올바르지 않습니다: \(revision.uuidString.lowercased())"
        case .writeConflict(let type, let id):
            "다른 창에서 Steam 실행 구성이 변경되었습니다: \(type)=\(id)"
        case .incompleteLaunchRecordProjection:
            "실행 기록에 구성 스냅샷과 트랜잭션 저널을 함께 제공해야 합니다."
        case .requestedTransactionCannotBeRecorded:
            "해결되지 않은 요청 상태의 Steam 실행 구성은 실행 기록에 저장할 수 없습니다."
        case .transactionConfigurationMismatch:
            "Steam 실행 구성과 트랜잭션 저널의 해결 결과가 일치하지 않습니다."
        }
    }
}

private let zeroSteamLaunchConfigurationPersistenceRevision =
    "00000000-0000-0000-0000-000000000000"

private func isValidSteamLaunchConfigurationPersistenceRevision(_ revision: UUID) -> Bool {
    revision.uuidString.lowercased() != zeroSteamLaunchConfigurationPersistenceRevision
}

private func makeSteamLaunchConfigurationPersistenceRevision(
    excluding existing: UUID? = nil
) -> UUID {
    while true {
        let candidate = UUID()
        if isValidSteamLaunchConfigurationPersistenceRevision(candidate), candidate != existing {
            return candidate
        }
    }
}

@Model
final class StandardSteamLaunchConfigurationRecord {
    static let recordID = "standard-default"

    @Attribute(.unique) var id: String
    var schemaVersion: Int
    var canonicalConfigurationPayload: Data
    var configurationDigest: String
    var persistenceRevision: UUID
    var createdAt: Date
    var updatedAt: Date

    init(snapshot: SteamLaunchConfigurationSnapshot, now: Date = Date()) throws {
        let projection = try Self.makeProjection(snapshot: snapshot)
        self.id = Self.recordID
        self.schemaVersion = projection.schemaVersion
        self.canonicalConfigurationPayload = projection.payload
        self.configurationDigest = projection.digest
        self.persistenceRevision = makeSteamLaunchConfigurationPersistenceRevision()
        self.createdAt = now
        self.updatedAt = now
    }

    func decodedSnapshot() throws -> SteamLaunchConfigurationSnapshot {
        guard id == Self.recordID else {
            throw SteamLaunchConfigurationPersistenceError.recordIdentityMismatch("standard-id")
        }
        guard isValidSteamLaunchConfigurationPersistenceRevision(persistenceRevision) else {
            throw SteamLaunchConfigurationPersistenceError.invalidPersistenceRevision(
                persistenceRevision
            )
        }
        let snapshot = try SteamLaunchConfigurationSnapshot(
            canonicalPayload: canonicalConfigurationPayload
        )
        guard snapshot.identity.mode == .standard else {
            throw SteamLaunchConfigurationPersistenceError.unexpectedMode(
                expected: .standard,
                actual: snapshot.identity.mode
            )
        }
        guard snapshot.identity.configurationIdentity == Self.recordID else {
            throw SteamLaunchConfigurationPersistenceError.recordIdentityMismatch(
                "standard-configuration-identity"
            )
        }
        guard schemaVersion == snapshot.schemaVersion else {
            throw SteamLaunchConfigurationPersistenceError.schemaVersionMismatch(
                stored: schemaVersion,
                decoded: snapshot.schemaVersion
            )
        }
        guard configurationDigest == (try snapshot.canonicalDigest) else {
            throw SteamLaunchConfigurationPersistenceError.digestMismatch
        }
        return snapshot
    }

    func replace(with snapshot: SteamLaunchConfigurationSnapshot, now: Date) throws {
        guard id == Self.recordID else {
            throw SteamLaunchConfigurationPersistenceError.recordIdentityMismatch("standard-id")
        }
        let projection = try Self.makeProjection(snapshot: snapshot)
        guard isValidSteamLaunchConfigurationPersistenceRevision(persistenceRevision) else {
            throw SteamLaunchConfigurationPersistenceError.invalidPersistenceRevision(
                persistenceRevision
            )
        }
        let nextRevision = makeSteamLaunchConfigurationPersistenceRevision(
            excluding: persistenceRevision
        )
        schemaVersion = projection.schemaVersion
        canonicalConfigurationPayload = projection.payload
        configurationDigest = projection.digest
        persistenceRevision = nextRevision
        updatedAt = now
    }

    private static func makeProjection(
        snapshot: SteamLaunchConfigurationSnapshot
    ) throws -> (schemaVersion: Int, payload: Data, digest: String) {
        try snapshot.validate()
        guard snapshot.identity.mode == .standard else {
            throw SteamLaunchConfigurationPersistenceError.unexpectedMode(
                expected: .standard,
                actual: snapshot.identity.mode
            )
        }
        guard snapshot.identity.configurationIdentity == Self.recordID else {
            throw SteamLaunchConfigurationPersistenceError.recordIdentityMismatch(
                "standard-configuration-identity"
            )
        }
        let payload = try snapshot.canonicalPayload()
        let decoded = try SteamLaunchConfigurationSnapshot(canonicalPayload: payload)
        guard decoded == snapshot else {
            throw SteamLaunchConfigurationPersistenceError.recordIdentityMismatch(
                "standard-canonical-round-trip"
            )
        }
        return (snapshot.schemaVersion, payload, try snapshot.canonicalDigest)
    }
}

@Model
final class CompatibilitySteamLaunchPreferenceRecord {
    @Attribute(.unique) var id: String
    var steamAppID: String
    var profileID: String
    var recipeRevision: String
    var schemaVersion: Int
    var canonicalPreferencePayload: Data
    var preferenceDigest: String
    // Version-1 compatibility preferences use payload digest + generation as their CAS source.
    // Zero is reserved for the undeployed snapshot-v1 source representation.
    var generation: Int64 = 0
    var persistenceRevision: UUID
    var createdAt: Date
    var updatedAt: Date

    init(snapshot: SteamLaunchConfigurationSnapshot, now: Date = Date()) throws {
        let projection = try Self.makeProjection(snapshot: snapshot)
        self.id = projection.identity.deterministicRecordID
        self.steamAppID = projection.identity.steamAppID
        self.profileID = projection.identity.profileID
        self.recipeRevision = projection.identity.recipeRevision
        self.schemaVersion = projection.schemaVersion
        self.canonicalPreferencePayload = projection.payload
        self.preferenceDigest = projection.digest
        self.persistenceRevision = makeSteamLaunchConfigurationPersistenceRevision()
        self.createdAt = now
        self.updatedAt = now
    }

    func decodedSnapshot() throws -> SteamLaunchConfigurationSnapshot {
        guard generation == 0 else {
            throw SteamCompatibilityLaunchProfileErrorV1.migrationRejected(
                "legacy-generation"
            )
        }
        guard isValidSteamLaunchConfigurationPersistenceRevision(persistenceRevision) else {
            throw SteamLaunchConfigurationPersistenceError.invalidPersistenceRevision(
                persistenceRevision
            )
        }
        let snapshot = try SteamLaunchConfigurationSnapshot(
            canonicalPayload: canonicalPreferencePayload
        )
        guard case .compatibility(let identity) = snapshot.identity else {
            throw SteamLaunchConfigurationPersistenceError.unexpectedMode(
                expected: .compatibility,
                actual: snapshot.identity.mode
            )
        }
        guard id == identity.deterministicRecordID else {
            throw SteamLaunchConfigurationPersistenceError.recordIdentityMismatch(
                "compatibility-record-id"
            )
        }
        guard steamAppID == identity.steamAppID,
              profileID == identity.profileID,
              recipeRevision == identity.recipeRevision else {
            throw SteamLaunchConfigurationPersistenceError.recordIdentityMismatch(
                "compatibility-identity-columns"
            )
        }
        guard schemaVersion == snapshot.schemaVersion else {
            throw SteamLaunchConfigurationPersistenceError.schemaVersionMismatch(
                stored: schemaVersion,
                decoded: snapshot.schemaVersion
            )
        }
        guard preferenceDigest == (try snapshot.canonicalDigest) else {
            throw SteamLaunchConfigurationPersistenceError.digestMismatch
        }
        return snapshot
    }

    func replace(with snapshot: SteamLaunchConfigurationSnapshot, now: Date) throws {
        guard generation == 0 else {
            throw SteamCompatibilityLaunchProfileErrorV1.migrationRejected(
                "legacy-generation"
            )
        }
        let projection = try Self.makeProjection(snapshot: snapshot)
        guard id == projection.identity.deterministicRecordID,
              steamAppID == projection.identity.steamAppID,
              profileID == projection.identity.profileID,
              recipeRevision == projection.identity.recipeRevision else {
            throw SteamLaunchConfigurationPersistenceError.recordIdentityMismatch(
                "compatibility-replacement-target"
            )
        }
        guard isValidSteamLaunchConfigurationPersistenceRevision(persistenceRevision) else {
            throw SteamLaunchConfigurationPersistenceError.invalidPersistenceRevision(
                persistenceRevision
            )
        }
        let nextRevision = makeSteamLaunchConfigurationPersistenceRevision(
            excluding: persistenceRevision
        )
        schemaVersion = projection.schemaVersion
        canonicalPreferencePayload = projection.payload
        preferenceDigest = projection.digest
        persistenceRevision = nextRevision
        updatedAt = now
    }

    private static func makeProjection(
        snapshot: SteamLaunchConfigurationSnapshot
    ) throws -> (
        identity: SteamCompatibilityProfileIdentity,
        schemaVersion: Int,
        payload: Data,
        digest: String
    ) {
        try snapshot.validate()
        guard case .compatibility(let identity) = snapshot.identity else {
            throw SteamLaunchConfigurationPersistenceError.unexpectedMode(
                expected: .compatibility,
                actual: snapshot.identity.mode
            )
        }
        let payload = try snapshot.canonicalPayload()
        let decoded = try SteamLaunchConfigurationSnapshot(canonicalPayload: payload)
        guard decoded == snapshot else {
            throw SteamLaunchConfigurationPersistenceError.recordIdentityMismatch(
                "compatibility-canonical-round-trip"
            )
        }
        return (identity, snapshot.schemaVersion, payload, try snapshot.canonicalDigest)
    }
}

extension ModelContext {
    fileprivate func fetchCanonicalStandardSteamLaunchConfigurationSingleton()
        throws -> StandardSteamLaunchConfigurationRecord?
    {
        var descriptor = FetchDescriptor<StandardSteamLaunchConfigurationRecord>()
        descriptor.fetchLimit = 2
        let matches = try fetch(descriptor)
        let recordID = StandardSteamLaunchConfigurationRecord.recordID
        guard matches.count <= 1 else {
            throw SteamLaunchConfigurationPersistenceError.duplicateRecord(
                type: "standard",
                id: recordID
            )
        }
        guard let record = matches.first else { return nil }
        guard record.id == recordID else {
            throw SteamLaunchConfigurationPersistenceError.recordIdentityMismatch(
                "standard-table-singleton-id"
            )
        }
        return record
    }

    @discardableResult
    func upsertStandardSteamLaunchConfiguration(
        _ snapshot: SteamLaunchConfigurationSnapshot,
        now: Date = Date()
    ) throws -> StandardSteamLaunchConfigurationRecord {
        guard !hasChanges else {
            throw SteamLaunchConfigurationPersistenceError.contextHasPendingChanges
        }
        do {
            guard snapshot.identity.mode == .standard else {
                throw SteamLaunchConfigurationPersistenceError.unexpectedMode(
                    expected: .standard,
                    actual: snapshot.identity.mode
                )
            }
            let record: StandardSteamLaunchConfigurationRecord
            if let existing = try fetchCanonicalStandardSteamLaunchConfigurationSingleton() {
                _ = try existing.decodedSnapshot()
                try existing.replace(with: snapshot, now: now)
                record = existing
            } else {
                record = try StandardSteamLaunchConfigurationRecord(snapshot: snapshot, now: now)
                insert(record)
            }
            try saveOrRollback()
            return record
        } catch {
            if hasChanges {
                rollback()
            }
            throw error
        }
    }

    @discardableResult
    func upsertCompatibilitySteamLaunchPreference(
        _ snapshot: SteamLaunchConfigurationSnapshot,
        now: Date = Date()
    ) throws -> CompatibilitySteamLaunchPreferenceRecord {
        guard !hasChanges else {
            throw SteamLaunchConfigurationPersistenceError.contextHasPendingChanges
        }
        do {
            guard case .compatibility(let identity) = snapshot.identity else {
                throw SteamLaunchConfigurationPersistenceError.unexpectedMode(
                    expected: .compatibility,
                    actual: snapshot.identity.mode
                )
            }
            let recordID = identity.deterministicRecordID
            let descriptor = FetchDescriptor<CompatibilitySteamLaunchPreferenceRecord>(
                predicate: #Predicate { $0.id == recordID }
            )
            let matches = try fetch(descriptor)
            guard matches.count <= 1 else {
                throw SteamLaunchConfigurationPersistenceError.duplicateRecord(
                    type: "compatibility",
                    id: recordID
                )
            }
            let record: CompatibilitySteamLaunchPreferenceRecord
            if let existing = matches.first {
                _ = try existing.decodedSnapshot()
                try existing.replace(with: snapshot, now: now)
                record = existing
            } else {
                record = try CompatibilitySteamLaunchPreferenceRecord(snapshot: snapshot, now: now)
                insert(record)
            }
            try saveOrRollback()
            return record
        } catch {
            if hasChanges {
                rollback()
            }
            throw error
        }
    }
}

struct SteamLaunchConfigurationRecordVersion: Hashable, Sendable {
    let digest: String
    let revision: UUID
}

struct SteamLaunchConfigurationStoredSnapshot: Hashable, Sendable {
    let snapshot: SteamLaunchConfigurationSnapshot
    let version: SteamLaunchConfigurationRecordVersion
}

@MainActor
struct SteamLaunchConfigurationRepository {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func loadStandard() throws -> SteamLaunchConfigurationStoredSnapshot? {
        let context = makeContext()
        return try fetchStandard(in: context).map {
            try standardStoredSnapshot(from: $0)
        }
    }

    /// Returns the exact persisted CAS token without decoding or validating the payload.
    /// This is intentionally limited to explicit recovery of a record the caller inspected.
    func standardRecordVersionForRecovery() throws -> SteamLaunchConfigurationRecordVersion? {
        let context = makeContext()
        return try fetchStandard(in: context).map {
            standardRawRecordVersion(from: $0)
        }
    }

    @discardableResult
    func saveStandard(
        _ snapshot: SteamLaunchConfigurationSnapshot,
        expectedVersion: SteamLaunchConfigurationRecordVersion?,
        now: Date = Date()
    ) throws -> SteamLaunchConfigurationStoredSnapshot {
        try snapshot.validate()
        guard snapshot.identity.mode == .standard else {
            throw SteamLaunchConfigurationPersistenceError.unexpectedMode(
                expected: .standard,
                actual: snapshot.identity.mode
            )
        }

        let context = makeContext()
        let existing = try fetchStandard(in: context)
        let current = try existing.map {
            try standardStoredSnapshot(from: $0)
        }
        try require(
            expectedVersion,
            matches: current?.version,
            type: "standard",
            id: StandardSteamLaunchConfigurationRecord.recordID
        )
        let record = try context.upsertStandardSteamLaunchConfiguration(snapshot, now: now)
        return try standardStoredSnapshot(from: record)
    }

    func resetStandard(
        expectedVersion: SteamLaunchConfigurationRecordVersion?
    ) throws {
        let context = makeContext()
        let existing = try fetchStandard(in: context)
        let current = existing.map {
            standardRawRecordVersion(from: $0)
        }
        try require(
            expectedVersion,
            matches: current,
            type: "standard",
            id: StandardSteamLaunchConfigurationRecord.recordID
        )
        guard let existing else { return }
        context.delete(existing)
        try context.saveOrRollback()
    }

    func loadCompatibility(
        identity: SteamCompatibilityProfileIdentity
    ) throws -> SteamLaunchConfigurationStoredSnapshot? {
        let context = makeContext()
        return try fetchCompatibility(identity: identity, in: context)
            .map {
                try compatibilityStoredSnapshot(from: $0, expectedIdentity: identity)
            }
    }

    @discardableResult
    func saveCompatibility(
        _ snapshot: SteamLaunchConfigurationSnapshot,
        expectedVersion: SteamLaunchConfigurationRecordVersion?,
        now: Date = Date()
    ) throws -> SteamLaunchConfigurationStoredSnapshot {
        try snapshot.validate()
        guard case .compatibility(let identity) = snapshot.identity else {
            throw SteamLaunchConfigurationPersistenceError.unexpectedMode(
                expected: .compatibility,
                actual: snapshot.identity.mode
            )
        }

        let context = makeContext()
        let existing = try fetchCompatibility(identity: identity, in: context)
        let current = try existing.map {
            try compatibilityStoredSnapshot(from: $0, expectedIdentity: identity)
        }
        try require(
            expectedVersion,
            matches: current?.version,
            type: "compatibility",
            id: identity.deterministicRecordID
        )
        let record = try context.upsertCompatibilitySteamLaunchPreference(snapshot, now: now)
        return try compatibilityStoredSnapshot(from: record, expectedIdentity: identity)
    }

    func resetCompatibility(
        identity: SteamCompatibilityProfileIdentity,
        expectedVersion: SteamLaunchConfigurationRecordVersion?
    ) throws {
        let context = makeContext()
        let existing = try fetchCompatibility(identity: identity, in: context)
        let current = try existing.map {
            try compatibilityStoredSnapshot(from: $0, expectedIdentity: identity)
        }
        try require(
            expectedVersion,
            matches: current?.version,
            type: "compatibility",
            id: identity.deterministicRecordID
        )
        guard let existing else { return }
        context.delete(existing)
        try context.saveOrRollback()
    }

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func fetchStandard(
        in context: ModelContext
    ) throws -> StandardSteamLaunchConfigurationRecord? {
        try context.fetchCanonicalStandardSteamLaunchConfigurationSingleton()
    }

    private func fetchCompatibility(
        identity: SteamCompatibilityProfileIdentity,
        in context: ModelContext
    ) throws -> CompatibilitySteamLaunchPreferenceRecord? {
        let recordID = identity.deterministicRecordID
        let descriptor = FetchDescriptor<CompatibilitySteamLaunchPreferenceRecord>(
            predicate: #Predicate { $0.id == recordID }
        )
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else {
            throw SteamLaunchConfigurationPersistenceError.duplicateRecord(
                type: "compatibility",
                id: recordID
            )
        }
        return matches.first
    }

    private func standardStoredSnapshot(
        from record: StandardSteamLaunchConfigurationRecord
    ) throws -> SteamLaunchConfigurationStoredSnapshot {
        SteamLaunchConfigurationStoredSnapshot(
            snapshot: try record.decodedSnapshot(),
            version: standardRawRecordVersion(from: record)
        )
    }

    private func standardRawRecordVersion(
        from record: StandardSteamLaunchConfigurationRecord
    ) -> SteamLaunchConfigurationRecordVersion {
        SteamLaunchConfigurationRecordVersion(
            digest: record.configurationDigest,
            revision: record.persistenceRevision
        )
    }

    private func compatibilityStoredSnapshot(
        from record: CompatibilitySteamLaunchPreferenceRecord,
        expectedIdentity: SteamCompatibilityProfileIdentity
    ) throws -> SteamLaunchConfigurationStoredSnapshot {
        let snapshot = try record.decodedSnapshot()
        guard snapshot.identity.compatibilityProfile == expectedIdentity else {
            throw SteamLaunchConfigurationPersistenceError.recordIdentityMismatch(
                "compatibility-repository-identity"
            )
        }
        return SteamLaunchConfigurationStoredSnapshot(
            snapshot: snapshot,
            version: SteamLaunchConfigurationRecordVersion(
                digest: record.preferenceDigest,
                revision: record.persistenceRevision
            )
        )
    }

    private func require(
        _ expected: SteamLaunchConfigurationRecordVersion?,
        matches actual: SteamLaunchConfigurationRecordVersion?,
        type: String,
        id: String
    ) throws {
        guard expected == actual else {
            throw SteamLaunchConfigurationPersistenceError.writeConflict(type: type, id: id)
        }
    }
}

@Model
final class PrefixRecord {
    @Attribute(.unique) var id: String
    var environmentGenerationID: String?
    var displayName: String
    var path: String
    var mode: String
    var runner: String
    var runnerBuildFingerprint: String?
    var prefixCompatibilityFingerprint: String?
    var architecture: String
    var windowsVersion: String
    var installedRuntimesJSON: String
    var dllOverridesJSON: String
    var launchOptionsJSON: String
    var snapshotsJSON: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        environmentGenerationID: String? = nil,
        displayName: String,
        path: String,
        mode: PrefixMode = .steamShared,
        runner: String = WinePrefixDefaults.runner,
        runnerBuildFingerprint: String? = nil,
        prefixCompatibilityFingerprint: String? = nil,
        architecture: String = WinePrefixDefaults.architecture,
        windowsVersion: String = WinePrefixDefaults.windowsVersion,
        installedRuntimesJSON: String = "[]",
        dllOverridesJSON: String = "[]",
        launchOptionsJSON: String = "[]",
        snapshotsJSON: String = "[]",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.environmentGenerationID = environmentGenerationID
        self.displayName = displayName
        self.path = path
        self.mode = mode.rawValue
        self.runner = runner
        self.runnerBuildFingerprint = runnerBuildFingerprint
        self.prefixCompatibilityFingerprint = prefixCompatibilityFingerprint
        self.architecture = architecture
        self.windowsVersion = windowsVersion
        self.installedRuntimesJSON = installedRuntimesJSON
        self.dllOverridesJSON = dllOverridesJSON
        self.launchOptionsJSON = launchOptionsJSON
        self.snapshotsJSON = snapshotsJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum PrefixRecordProjectionError: LocalizedError {
    case encodeFailed(String)
    case utf8ConversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .encodeFailed(let field):
            "프리픽스 기록의 \(field) 값을 JSON으로 변환할 수 없습니다."
        case .utf8ConversionFailed(let field):
            "프리픽스 기록의 \(field) JSON을 UTF-8 문자열로 변환할 수 없습니다."
        }
    }
}

extension PrefixRecord {
    @discardableResult
    static func upsert(metadata: PrefixMetadata, in context: ModelContext) throws -> PrefixRecord {
        let existing = try context.fetch(FetchDescriptor<PrefixRecord>())
        if let record = existing.first(where: { $0.id == metadata.id }) {
            try record.apply(metadata: metadata)
            return record
        }

        let record = PrefixRecord(
            id: metadata.id,
            environmentGenerationID: metadata.environmentGenerationID,
            displayName: metadata.displayName,
            path: metadata.path,
            mode: metadata.mode,
            runner: metadata.runner,
            runnerBuildFingerprint: metadata.runtimeBinding?.runnerBuildFingerprint,
            prefixCompatibilityFingerprint: metadata.runtimeBinding?.prefixCompatibilityFingerprint,
            architecture: metadata.architecture,
            windowsVersion: metadata.windowsVersion,
            installedRuntimesJSON: try encodedArray(metadata.installedRuntimes, field: "installedRuntimes"),
            dllOverridesJSON: try encodedArray(metadata.dllOverrides, field: "dllOverrides"),
            launchOptionsJSON: try encodedArray(metadata.launchOptions, field: "launchOptions"),
            snapshotsJSON: try encodedArray(metadata.snapshots, field: "snapshots"),
            createdAt: metadata.createdAt,
            updatedAt: metadata.updatedAt
        )
        context.insert(record)
        return record
    }

    private func apply(metadata: PrefixMetadata) throws {
        environmentGenerationID = metadata.environmentGenerationID
        displayName = metadata.displayName
        path = metadata.path
        mode = metadata.mode.rawValue
        runner = metadata.runner
        runnerBuildFingerprint = metadata.runtimeBinding?.runnerBuildFingerprint
        prefixCompatibilityFingerprint = metadata.runtimeBinding?.prefixCompatibilityFingerprint
        architecture = metadata.architecture
        windowsVersion = metadata.windowsVersion
        installedRuntimesJSON = try Self.encodedArray(metadata.installedRuntimes, field: "installedRuntimes")
        dllOverridesJSON = try Self.encodedArray(metadata.dllOverrides, field: "dllOverrides")
        launchOptionsJSON = try Self.encodedArray(metadata.launchOptions, field: "launchOptions")
        snapshotsJSON = try Self.encodedArray(metadata.snapshots, field: "snapshots")
        updatedAt = metadata.updatedAt
    }

    private static func encodedArray<T: Encodable>(_ value: [T], field: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw PrefixRecordProjectionError.encodeFailed(field)
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw PrefixRecordProjectionError.utf8ConversionFailed(field)
        }
        return json
    }
}

@Model
final class RuntimeRecord {
    @Attribute(.unique) var id: String
    var prefixId: String
    var runtime: String
    var status: String
    var installedAt: Date?
    var installerSource: String
    var installLogPath: String?

    init(
        id: String,
        prefixId: String,
        runtime: RuntimeId,
        status: String = "notInstalled",
        installedAt: Date? = nil,
        installerSource: String = "user-selected",
        installLogPath: String? = nil
    ) {
        self.id = id
        self.prefixId = prefixId
        self.runtime = runtime.rawValue
        self.status = status
        self.installedAt = installedAt
        self.installerSource = installerSource
        self.installLogPath = installLogPath
    }
}

@Model
final class SteamGameRecord {
    @Attribute(.unique) var steamAppId: String
    var name: String
    var installDir: String
    var libraryPath: String
    var manifestPath: String
    var sizeOnDisk: Int64
    var lastUpdated: Date?
    var lastLaunchStatus: String?
    var graphicsBackendSelection: String?
    var libraryBookmark: Data?

    init(
        steamAppId: String,
        name: String,
        installDir: String,
        libraryPath: String,
        manifestPath: String,
        sizeOnDisk: Int64 = 0,
        lastUpdated: Date? = nil,
        lastLaunchStatus: String? = nil,
        graphicsBackendSelection: String? = nil,
        libraryBookmark: Data? = nil
    ) {
        self.steamAppId = steamAppId
        self.name = name
        self.installDir = installDir
        self.libraryPath = libraryPath
        self.manifestPath = manifestPath
        self.sizeOnDisk = sizeOnDisk
        self.lastUpdated = lastUpdated
        self.lastLaunchStatus = lastLaunchStatus
        self.graphicsBackendSelection = graphicsBackendSelection
        self.libraryBookmark = libraryBookmark
    }

    var game: SteamGame {
        SteamGame(
            steamAppId: steamAppId,
            name: name,
            installDir: installDir,
            libraryPath: libraryPath,
            manifestPath: manifestPath,
            sizeOnDisk: sizeOnDisk,
            lastUpdated: lastUpdated
        )
    }
}

struct SteamGameReferenceReconciliationResult: Hashable {
    var upsertedCount: Int
    var removedCount: Int
}

extension ModelContext {
    @discardableResult
    func reconcileSteamGameReferences(
        _ scannedGames: [SteamGame],
        libraryBookmarksByPath: [String: Data] = [:],
        removesStaleRecords: Bool
    ) throws -> SteamGameReferenceReconciliationResult {
        let records = try fetch(FetchDescriptor<SteamGameRecord>())
        var recordsByAppID = Dictionary(uniqueKeysWithValues: records.map { ($0.steamAppId, $0) })
        let scannedAppIDs = Set(scannedGames.map(\.steamAppId))

        for game in scannedGames {
            let normalizedLibraryPath = URL(
                fileURLWithPath: game.libraryPath,
                isDirectory: true
            ).standardizedFileURL.path
            if let record = recordsByAppID[game.steamAppId] {
                record.name = game.name
                record.installDir = game.installDir
                record.libraryPath = game.libraryPath
                record.manifestPath = game.manifestPath
                record.sizeOnDisk = game.sizeOnDisk
                record.lastUpdated = game.lastUpdated
                if let bookmark = libraryBookmarksByPath[normalizedLibraryPath] {
                    record.libraryBookmark = bookmark
                }
            } else {
                let record = SteamGameRecord(
                    steamAppId: game.steamAppId,
                    name: game.name,
                    installDir: game.installDir,
                    libraryPath: game.libraryPath,
                    manifestPath: game.manifestPath,
                    sizeOnDisk: game.sizeOnDisk,
                    lastUpdated: game.lastUpdated,
                    libraryBookmark: libraryBookmarksByPath[normalizedLibraryPath]
                )
                insert(record)
                recordsByAppID[game.steamAppId] = record
            }
        }

        var removedCount = 0
        if removesStaleRecords {
            for record in records where !scannedAppIDs.contains(record.steamAppId) {
                delete(record)
                removedCount += 1
            }
        }
        return SteamGameReferenceReconciliationResult(
            upsertedCount: scannedGames.count,
            removedCount: removedCount
        )
    }
}

@Model
final class SteamStorageMountRecord {
    @Attribute(.unique) var id: String
    var path: String
    var bookmark: Data?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = "steam-storage-\(UUID().uuidString)",
        path: String,
        bookmark: Data? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.path = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        self.bookmark = bookmark
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

extension ModelContext {
    @discardableResult
    func upsertSteamStorageMount(
        url: URL,
        bookmark: Data?,
        now: Date = Date()
    ) throws -> SteamStorageMountRecord {
        let normalizedPath = url.standardizedFileURL.path
        let records = try fetch(FetchDescriptor<SteamStorageMountRecord>())
        if let existing = records.first(where: {
            URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL.path == normalizedPath
        }) {
            existing.path = normalizedPath
            if let bookmark {
                existing.bookmark = bookmark
            }
            existing.updatedAt = now
            return existing
        }

        let record = SteamStorageMountRecord(
            path: normalizedPath,
            bookmark: bookmark,
            createdAt: now,
            updatedAt: now
        )
        insert(record)
        return record
    }
}

struct SteamLaunchSelectedGameContext: Hashable, Sendable {
    static let associationSource = "selectedReferenceAtSteamLaunchNotExecutionVerified"

    var steamAppID: String
    var name: String
    var buildID: String?
    var manifestStateFlags: Int?
    var installedByteCount: Int64
    var lastUpdated: Date?
    var manifestAvailable: Bool
    var manifestCaptureIssue: String?
}

@Model
final class LaunchRecord {
    @Attribute(.unique) var id: String
    var gameId: String?
    var prefixId: String
    var commandKind: String
    var startedAt: Date
    var endedAt: Date?
    /// The operating-system exit status, when a process actually exited.
    var exitCode: Int32?
    /// ForgePlay's own launch/verification decision code.
    /// This must never be presented as a process exit status.
    var forgePlayStatusCode: Int32?
    var stdoutPath: String?
    var stderrPath: String?
    var diagnosticLogPath: String?
    var status: String
    var steamUIVerificationStatus: String?
    var steamUIVerificationDetail: String?
    var steamUISurfaceRawValue: String?
    var hostAppSessionID: String?
    var environmentGenerationID: String?
    var processSteamUIVerificationStatus: String?
    var didTimeOut: Bool?
    var waitedForExit: Bool?
    var processIdentifier: Int32?
    var processOutcome: String?
    var terminationSignal: Int32?
    var rawWaitStatus: Int32?
    var processObservationPath: String?
    var runEvidencePath: String?
    // An inline schema default is required for lightweight migration of stores
    // created before related process-evidence links were persisted.
    var relatedRunEvidencePaths: [String] = []
    var evidenceCaptureWarning: String?
    var diagnosticCaptureWarning: String?
    var failureDomain: String?
    var failureCode: Int?
    var failureSummary: String?
    var gameName: String?
    var gameBuildID: String?
    var gameManifestStateFlags: Int?
    var gameInstalledByteCount: Int64?
    var gameLastUpdatedAt: Date?
    var gameManifestAvailable: Bool?
    var gameManifestCaptureIssue: String?
    var gameAssociationSource: String?
    var launchModeRawValue: String? = nil
    var launchConfigurationIdentity: String? = nil
    var launchConfigurationSchemaVersion: Int? = nil
    var launchConfigurationPayload: Data? = nil
    var launchConfigurationDigest: String? = nil
    var launchConfigurationTransactionID: String? = nil
    var launchConfigurationTransactionState: String? = nil
    var launchConfigurationRestorationState: String? = nil

    init(
        id: String = "launch-\(UUID().uuidString)",
        gameId: String? = nil,
        prefixId: String,
        commandKind: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        forgePlayStatusCode: Int32? = nil,
        stdoutPath: String? = nil,
        stderrPath: String? = nil,
        diagnosticLogPath: String? = nil,
        status: String = "running",
        steamUIVerificationStatus: String? = SteamUIVerificationState.notRun.rawValue,
        steamUIVerificationDetail: String? = nil,
        steamUISurfaceRawValue: String? = nil,
        hostAppSessionID: String? = nil,
        environmentGenerationID: String? = nil,
        processSteamUIVerificationStatus: String? = nil,
        didTimeOut: Bool? = nil,
        waitedForExit: Bool? = nil,
        processIdentifier: Int32? = nil,
        processOutcome: String? = nil,
        terminationSignal: Int32? = nil,
        rawWaitStatus: Int32? = nil,
        processObservationPath: String? = nil,
        runEvidencePath: String? = nil,
        relatedRunEvidencePaths: [String] = [],
        evidenceCaptureWarning: String? = nil,
        diagnosticCaptureWarning: String? = nil,
        failureDomain: String? = nil,
        failureCode: Int? = nil,
        failureSummary: String? = nil,
        gameName: String? = nil,
        gameBuildID: String? = nil,
        gameManifestStateFlags: Int? = nil,
        gameInstalledByteCount: Int64? = nil,
        gameLastUpdatedAt: Date? = nil,
        gameManifestAvailable: Bool? = nil,
        gameManifestCaptureIssue: String? = nil,
        gameAssociationSource: String? = nil,
        launchModeRawValue: String? = nil,
        launchConfigurationIdentity: String? = nil,
        launchConfigurationSchemaVersion: Int? = nil,
        launchConfigurationPayload: Data? = nil,
        launchConfigurationDigest: String? = nil,
        launchConfigurationTransactionID: String? = nil,
        launchConfigurationTransactionState: String? = nil,
        launchConfigurationRestorationState: String? = nil
    ) {
        self.id = id
        self.gameId = gameId
        self.prefixId = prefixId
        self.commandKind = commandKind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.forgePlayStatusCode = forgePlayStatusCode
        self.stdoutPath = stdoutPath
        self.stderrPath = stderrPath
        self.diagnosticLogPath = diagnosticLogPath
        self.status = status
        self.steamUIVerificationStatus = steamUIVerificationStatus
        self.steamUIVerificationDetail = steamUIVerificationDetail
        self.steamUISurfaceRawValue = steamUISurfaceRawValue
        self.hostAppSessionID = hostAppSessionID
        self.environmentGenerationID = environmentGenerationID
        self.processSteamUIVerificationStatus = processSteamUIVerificationStatus
        self.didTimeOut = didTimeOut
        self.waitedForExit = waitedForExit
        self.processIdentifier = processIdentifier
        self.processOutcome = processOutcome
        self.terminationSignal = terminationSignal
        self.rawWaitStatus = rawWaitStatus
        self.processObservationPath = processObservationPath
        self.runEvidencePath = runEvidencePath
        self.relatedRunEvidencePaths = relatedRunEvidencePaths
        self.evidenceCaptureWarning = evidenceCaptureWarning
        self.diagnosticCaptureWarning = diagnosticCaptureWarning
        self.failureDomain = failureDomain
        self.failureCode = failureCode
        self.failureSummary = failureSummary
        self.gameName = gameName
        self.gameBuildID = gameBuildID
        self.gameManifestStateFlags = gameManifestStateFlags
        self.gameInstalledByteCount = gameInstalledByteCount
        self.gameLastUpdatedAt = gameLastUpdatedAt
        self.gameManifestAvailable = gameManifestAvailable
        self.gameManifestCaptureIssue = gameManifestCaptureIssue
        self.gameAssociationSource = gameAssociationSource
        self.launchModeRawValue = launchModeRawValue
        self.launchConfigurationIdentity = launchConfigurationIdentity
        self.launchConfigurationSchemaVersion = launchConfigurationSchemaVersion
        self.launchConfigurationPayload = launchConfigurationPayload
        self.launchConfigurationDigest = launchConfigurationDigest
        self.launchConfigurationTransactionID = launchConfigurationTransactionID
        self.launchConfigurationTransactionState = launchConfigurationTransactionState
        self.launchConfigurationRestorationState = launchConfigurationRestorationState
    }
}

extension LaunchRecord {
    func bindResolvedLaunchConfiguration(
        snapshot: SteamLaunchConfigurationSnapshot?,
        journal: SteamLaunchConfigurationTransactionJournal?
    ) throws {
        switch (snapshot, journal) {
        case (nil, nil):
            launchModeRawValue = nil
            launchConfigurationIdentity = nil
            launchConfigurationSchemaVersion = nil
            launchConfigurationPayload = nil
            launchConfigurationDigest = nil
            launchConfigurationTransactionID = nil
            launchConfigurationTransactionState = nil
            launchConfigurationRestorationState = nil
        case (.some(let snapshot), .some(let journal)):
            try snapshot.validate()
            try journal.validate()
            guard journal.state != .requested else {
                throw SteamLaunchConfigurationPersistenceError.requestedTransactionCannotBeRecorded
            }
            let digest = try snapshot.canonicalDigest
            guard journal.resolvedDigest == digest else {
                throw SteamLaunchConfigurationPersistenceError.transactionConfigurationMismatch
            }
            let payload = try snapshot.canonicalPayload()
            let decoded = try SteamLaunchConfigurationSnapshot(canonicalPayload: payload)
            guard decoded == snapshot else {
                throw SteamLaunchConfigurationPersistenceError.transactionConfigurationMismatch
            }

            launchModeRawValue = snapshot.identity.mode.rawValue
            launchConfigurationIdentity = snapshot.identity.configurationIdentity
            launchConfigurationSchemaVersion = snapshot.schemaVersion
            launchConfigurationPayload = payload
            launchConfigurationDigest = digest
            launchConfigurationTransactionID = journal.transactionID.uuidString.lowercased()
            launchConfigurationTransactionState = journal.state.rawValue
            launchConfigurationRestorationState = journal.restorationState.rawValue
        case (.some, nil), (nil, .some):
            throw SteamLaunchConfigurationPersistenceError.incompleteLaunchRecordProjection
        }
    }

    var steamUIVerificationState: SteamUIVerificationState {
        steamUIVerificationStatus
            .flatMap(SteamUIVerificationState.init(rawValue:)) ?? .notRun
    }

    var steamUISurface: SteamUISurface? {
        steamUISurfaceRawValue.flatMap(SteamUISurface.init(rawValue:))
    }

    func applySteamLaunchResult(_ result: ProcessRunResult) {
        endedAt = result.endedAt
        exitCode = result.processExitCode
        forgePlayStatusCode = result.forgePlayStatusCode
        stdoutPath = result.stdoutLog.path
        stderrPath = result.stderrLog.path
        diagnosticLogPath = result.diagnosticLog?.path
        didTimeOut = result.didTimeOut
        waitedForExit = result.waitedForExit
        processIdentifier = result.processIdentifier
        processOutcome = result.outcome.rawValue
        terminationSignal = result.terminationSignal
        rawWaitStatus = result.rawWaitStatus
        processObservationPath = result.processObservationLog?.path
        runEvidencePath = result.runEvidenceLog?.path
        relatedRunEvidencePaths = result.relatedRunEvidenceLogs.map(\.path)
        evidenceCaptureWarning = result.evidenceCaptureWarning
        diagnosticCaptureWarning = result.diagnosticCaptureWarning
        failureDomain = nil
        failureCode = nil
        failureSummary = nil

        let uiState = resolvedSteamUIVerificationState(
            previous: steamUIVerificationStatus,
            inferred: SteamUIVerificationState.inferred(from: result)
        )
        processSteamUIVerificationStatus = SteamUIVerificationState.inferred(from: result).rawValue
        steamUIVerificationStatus = uiState.rawValue
        if let surface = result.steamUISurface {
            steamUISurfaceRawValue = surface.rawValue
        }
        if uiState != .rendered {
            steamUISurfaceRawValue = nil
        }
        switch uiState {
        case .launchedButUnverified:
            status = "launchedUnverified"
            if result.forgePlayStatusCode == SteamManager.steamLaunchProcessVerificationUnavailableExitCode {
                steamUIVerificationDetail = "The Windows Steam launch command was delivered, but process execution evidence could not be verified. Manual UI confirmation is required."
            } else {
                steamUIVerificationDetail = "Windows Steam process was started, but visible Steam UI rendering has not been verified."
            }
        case .blackScreenSuspected:
            status = "failed"
            steamUIVerificationDetail = "Windows Steam CEF/WebHelper rendering failure was detected after launch."
        case .failed:
            status = "failed"
            steamUIVerificationDetail = "Windows Steam launch failed before UI rendering could be verified."
        case .rendered:
            status = "finished"
            steamUIVerificationDetail = "Windows Steam UI rendering was verified."
        case .notRun:
            status = "running"
            steamUIVerificationDetail = nil
        }
    }

    private func resolvedSteamUIVerificationState(
        previous: String?,
        inferred: SteamUIVerificationState
    ) -> SteamUIVerificationState {
        let previousState = previous.flatMap(SteamUIVerificationState.init(rawValue:)) ?? .notRun
        switch (previousState, inferred) {
        case (.rendered, .launchedButUnverified),
             (.rendered, .rendered):
            return .rendered
        case (.blackScreenSuspected, .launchedButUnverified),
             (.blackScreenSuspected, .failed):
            return .blackScreenSuspected
        default:
            return inferred
        }
    }

    func markSteamLaunchFailedWithoutResult(
        now: Date = Date(),
        failureDomain: String? = nil,
        failureCode: Int? = nil,
        failureSummary: String? = nil,
        diagnosticLogPath: String? = nil
    ) {
        endedAt = now
        status = "failed"
        steamUIVerificationStatus = SteamUIVerificationState.failed.rawValue
        steamUISurfaceRawValue = nil
        steamUIVerificationDetail = "Windows Steam launch failed before a process result was recorded."
        processOutcome = ProcessRunOutcome.preflightFailed.rawValue
        self.failureDomain = failureDomain
        self.failureCode = failureCode
        self.failureSummary = failureSummary
        if let diagnosticLogPath {
            self.diagnosticLogPath = diagnosticLogPath
        }
    }

    func markSteamLaunchFailed(
        with result: ProcessRunResult,
        failureDomain: String? = nil,
        failureCode: Int? = nil,
        failureSummary: String? = nil
    ) {
        applySteamLaunchResult(result)
        status = "failed"
        steamUIVerificationStatus = SteamUIVerificationState.failed.rawValue
        steamUISurfaceRawValue = nil
        steamUIVerificationDetail =
            "Windows Steam launch workflow failed during process action '\(result.actionName)'; process evidence was preserved."
        self.failureDomain = failureDomain
        self.failureCode = failureCode
        self.failureSummary = failureSummary.map {
            "Process action '\(result.actionName)' failed: \($0)"
        } ?? "Process action '\(result.actionName)' failed."
    }

    func markSteamUIRendered(now: Date = Date()) {
        markSteamUISurface(.unknown, now: now)
    }

    func markSteamUISurface(_ surface: SteamUISurface, now: Date = Date()) {
        endedAt = endedAt ?? now
        status = "finished"
        steamUIVerificationStatus = SteamUIVerificationState.rendered.rawValue
        steamUISurfaceRawValue = surface.rawValue
        steamUIVerificationDetail = "Windows Steam \(surface.rawValue) UI was manually verified by the user."
    }

    func markSteamUIBlackScreenSuspected(now: Date = Date()) {
        endedAt = endedAt ?? now
        status = "failed"
        steamUIVerificationStatus = SteamUIVerificationState.blackScreenSuspected.rawValue
        steamUISurfaceRawValue = nil
        steamUIVerificationDetail = "Windows Steam UI was manually marked as black screen or not rendered."
    }
}

extension ModelContext {
    @discardableResult
    func createSteamLaunchRecord(
        appSessionID: String,
        environmentGenerationID: String? = nil,
        gameId: String? = nil,
        selectedGameContext: SteamLaunchSelectedGameContext? = nil,
        startedAt: Date = Date(),
        resolvedSnapshot: SteamLaunchConfigurationSnapshot? = nil,
        resolvedJournal: SteamLaunchConfigurationTransactionJournal? = nil
    ) throws -> LaunchRecord {
        let record = LaunchRecord(
            gameId: selectedGameContext?.steamAppID ?? gameId,
            prefixId: PrefixIdentifier.steamShared,
            commandKind: "launchSteam",
            startedAt: startedAt,
            hostAppSessionID: appSessionID,
            environmentGenerationID: environmentGenerationID,
            gameName: selectedGameContext?.name,
            gameBuildID: selectedGameContext?.buildID,
            gameManifestStateFlags: selectedGameContext?.manifestStateFlags,
            gameInstalledByteCount: selectedGameContext?.installedByteCount,
            gameLastUpdatedAt: selectedGameContext?.lastUpdated,
            gameManifestAvailable: selectedGameContext?.manifestAvailable,
            gameManifestCaptureIssue: selectedGameContext?.manifestCaptureIssue,
            gameAssociationSource: selectedGameContext == nil
                ? (gameId == nil ? nil : SteamLaunchSelectedGameContext.associationSource)
                : SteamLaunchSelectedGameContext.associationSource
        )
        try record.bindResolvedLaunchConfiguration(
            snapshot: resolvedSnapshot,
            journal: resolvedJournal
        )
        insert(record)
        try saveOrRollback()
        return record
    }

    func saveSteamLaunchResult(_ result: ProcessRunResult, for launchRecord: LaunchRecord) throws {
        launchRecord.applySteamLaunchResult(result)
        try saveOrRollback()
    }

    func markSteamLaunchFailedWithoutResult(
        _ launchRecord: LaunchRecord,
        now: Date = Date(),
        failureDomain: String? = nil,
        failureCode: Int? = nil,
        failureSummary: String? = nil,
        diagnosticLogPath: String? = nil
    ) throws {
        launchRecord.markSteamLaunchFailedWithoutResult(
            now: now,
            failureDomain: failureDomain,
            failureCode: failureCode,
            failureSummary: failureSummary,
            diagnosticLogPath: diagnosticLogPath
        )
        try saveOrRollback()
    }

    func markSteamLaunchFailed(
        _ launchRecord: LaunchRecord,
        with result: ProcessRunResult,
        failureDomain: String? = nil,
        failureCode: Int? = nil,
        failureSummary: String? = nil
    ) throws {
        launchRecord.markSteamLaunchFailed(
            with: result,
            failureDomain: failureDomain,
            failureCode: failureCode,
            failureSummary: failureSummary
        )
        try saveOrRollback()
    }

    func markSteamUIRendered(_ launchRecord: LaunchRecord, now: Date = Date()) throws {
        launchRecord.markSteamUIRendered(now: now)
        try saveOrRollback()
    }

    func markSteamUISurface(
        _ surface: SteamUISurface,
        for launchRecord: LaunchRecord,
        now: Date = Date()
    ) throws {
        launchRecord.markSteamUISurface(surface, now: now)
        try saveOrRollback()
    }

    func markSteamUIBlackScreenSuspected(_ launchRecord: LaunchRecord, now: Date = Date()) throws {
        launchRecord.markSteamUIBlackScreenSuspected(now: now)
        try saveOrRollback()
    }

    @discardableResult
    func reconcileAbandonedSteamLaunchRecords(
        currentAppSessionID: String,
        now: Date = Date()
    ) throws -> Int {
        let steamCommand = "launchSteam"
        let steamPrefixIdentifier = PrefixIdentifier.steamShared
        let runningStatus = "running"
        let notRunVerificationStatus = SteamUIVerificationState.notRun.rawValue

        // Keep both branches constrained in the persistent store. Expressing
        // the full conjunction with its trailing disjunction in one macro makes
        // Swift's predicate type checker exceed its complexity limit.
        let runningPredicate = #Predicate<LaunchRecord> {
            $0.commandKind == steamCommand &&
                $0.prefixId == steamPrefixIdentifier &&
                $0.hostAppSessionID != currentAppSessionID &&
                $0.status == runningStatus
        }
        let notRunPredicate = #Predicate<LaunchRecord> {
            $0.commandKind == steamCommand &&
                $0.prefixId == steamPrefixIdentifier &&
                $0.hostAppSessionID != currentAppSessionID &&
                $0.steamUIVerificationStatus == notRunVerificationStatus
        }
        let runningDescriptor = FetchDescriptor<LaunchRecord>(predicate: runningPredicate)
        let notRunDescriptor = FetchDescriptor<LaunchRecord>(predicate: notRunPredicate)

        var abandoned = try fetch(runningDescriptor)
        var abandonedRecordIDs: Set<String> = Set(abandoned.map(\.id))
        for record in try fetch(notRunDescriptor) {
            guard abandonedRecordIDs.insert(record.id).inserted else { continue }
            abandoned.append(record)
        }
        guard !abandoned.isEmpty else { return 0 }
        for record in abandoned {
            record.endedAt = record.endedAt ?? now
            record.status = "abandoned"
            record.steamUIVerificationStatus = SteamUIVerificationState.failed.rawValue
            record.steamUIVerificationDetail = "The ForgePlay app session ended before this Steam launch produced a result."
        }
        try saveOrRollback()
        return abandoned.count
    }
}

@Model
final class DiagnosticRecord {
    static let maxResultJSONBytes = 256 * 1024

    @Attribute(.unique) var id: String
    var gameId: String?
    var launchRecordId: String?
    var source: String
    var resultJSON: String
    var evidenceEnvelopeJSON: String?
    var evidenceEnvelopeSHA256: String?
    var executionReceiptJSON: String?
    var normalizedResultSHA256: String?
    var proposalDisposition: String?
    var createdAt: Date

    init(
        id: String = "diagnostic-\(UUID().uuidString)",
        gameId: String? = nil,
        launchRecordId: String? = nil,
        source: String,
        resultJSON: String,
        evidenceEnvelopeJSON: String? = nil,
        evidenceEnvelopeSHA256: String? = nil,
        executionReceiptJSON: String? = nil,
        normalizedResultSHA256: String? = nil,
        proposalDisposition: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.gameId = gameId
        self.launchRecordId = launchRecordId
        self.source = source
        self.resultJSON = resultJSON
        self.evidenceEnvelopeJSON = evidenceEnvelopeJSON
        self.evidenceEnvelopeSHA256 = evidenceEnvelopeSHA256
        self.executionReceiptJSON = executionReceiptJSON
        self.normalizedResultSHA256 = normalizedResultSHA256
        self.proposalDisposition = proposalDisposition
        self.createdAt = createdAt
    }
}

enum DiagnosticRecordDecodeError: LocalizedError, Equatable, Sendable {
    case invalidUTF8(String)
    case oversized(String, Int, Int)
    case decodeFailed(String)
    case invalidAIEvidenceMetadata(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8(let id):
            "저장된 진단 기록을 UTF-8로 읽지 못했습니다: \(id)"
        case .oversized(let id, let byteCount, let limit):
            "저장된 진단 기록이 너무 큽니다: \(id) \(byteCount) bytes / limit \(limit) bytes"
        case .decodeFailed(let id):
            "저장된 진단 기록을 읽지 못했습니다: \(id)"
        case .invalidAIEvidenceMetadata(let id):
            "저장된 AI 진단 증거 또는 실행 영수증이 결과와 일치하지 않습니다: \(id)"
        }
    }
}

struct DiagnosticRecordDecodeSnapshot: Sendable {
    let id: String
    let gameID: String?
    let launchRecordID: String?
    let source: String
    let resultJSON: String
    let evidenceEnvelopeJSON: String?
    let evidenceEnvelopeSHA256: String?
    let executionReceiptJSON: String?
    let normalizedResultSHA256: String?
    let proposalDisposition: String?
    let createdAt: Date

    init(
        id: String,
        gameID: String? = nil,
        launchRecordID: String? = nil,
        source: String,
        resultJSON: String,
        evidenceEnvelopeJSON: String? = nil,
        evidenceEnvelopeSHA256: String? = nil,
        executionReceiptJSON: String? = nil,
        normalizedResultSHA256: String? = nil,
        proposalDisposition: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.gameID = gameID
        self.launchRecordID = launchRecordID
        self.source = source
        self.resultJSON = resultJSON
        self.evidenceEnvelopeJSON = evidenceEnvelopeJSON
        self.evidenceEnvelopeSHA256 = evidenceEnvelopeSHA256
        self.executionReceiptJSON = executionReceiptJSON
        self.normalizedResultSHA256 = normalizedResultSHA256
        self.proposalDisposition = proposalDisposition
        self.createdAt = createdAt
    }

    init(record: DiagnosticRecord) {
        id = record.id
        gameID = record.gameId
        launchRecordID = record.launchRecordId
        source = record.source
        resultJSON = record.resultJSON
        evidenceEnvelopeJSON = record.evidenceEnvelopeJSON
        evidenceEnvelopeSHA256 = record.evidenceEnvelopeSHA256
        executionReceiptJSON = record.executionReceiptJSON
        normalizedResultSHA256 = record.normalizedResultSHA256
        proposalDisposition = record.proposalDisposition
        createdAt = record.createdAt
    }

    func requiredDecodedResult() throws -> DiagnosticResult {
        let data = try DiagnosticRecordPayloadDecoder.boundedUTF8Data(
            resultJSON,
            recordIdentifier: id,
            limit: DiagnosticRecord.maxResultJSONBytes
        )
        do {
            let result = try JSONDecoder().decode(DiagnosticResult.self, from: data)
            let normalized = LLMDiagnosticResultPolicy.normalizedResult(result, language: .system)
            try validateAIEvidenceMetadata(result: normalized)
            return normalized
        } catch {
            if let decodeError = error as? DiagnosticRecordDecodeError {
                throw decodeError
            }
            throw DiagnosticRecordDecodeError.decodeFailed(id)
        }
    }

    private func validateAIEvidenceMetadata(result: DiagnosticResult) throws {
        let metadataFields: [String?] = [
            evidenceEnvelopeJSON,
            evidenceEnvelopeSHA256,
            executionReceiptJSON,
            normalizedResultSHA256,
            proposalDisposition
        ]
        guard metadataFields.contains(where: { $0 != nil }) else { return }
        guard let evidenceEnvelopeJSON,
              let evidenceEnvelopeSHA256,
              let executionReceiptJSON,
              let normalizedResultSHA256,
              let proposalDisposition,
              evidenceEnvelopeJSON.utf8.count <= 64 * 1024,
              executionReceiptJSON.utf8.count <= 32 * 1024,
              ["shown-unapplied", "explicitly-approved", "rejected", "stale"]
                .contains(proposalDisposition) else {
            throw DiagnosticRecordDecodeError.invalidAIEvidenceMetadata(id)
        }
        let envelopeData = Data(evidenceEnvelopeJSON.utf8)
        guard AIDiagnosticCanonicalJSONV1.sha256Hex(envelopeData) == evidenceEnvelopeSHA256,
              let receiptData = executionReceiptJSON.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(
                AIDiagnosticEvidenceEnvelopeV1.self,
                from: envelopeData
              ),
              let receipt = try? JSONDecoder().decode(
                AIDiagnosticExecutionReceiptV1.self,
                from: receiptData
              ),
              envelope.schemaID == "com.forgeplay.ai-diagnostic-evidence-envelope.v1",
              receipt.schemaID == "com.forgeplay.ai-diagnostic-execution-receipt.v1",
              envelope.evidence.type == "untrusted-log-evidence",
              receipt.evidenceEnvelopeSHA256 == evidenceEnvelopeSHA256,
              receipt.normalizedResultSHA256 == normalizedResultSHA256,
              receipt.proposalDisposition == "shown-unapplied" else {
            throw DiagnosticRecordDecodeError.invalidAIEvidenceMetadata(id)
        }
        let resultProjection = try AIDiagnosticCanonicalJSONV1.encode(result)
        guard resultProjection.sha256 == normalizedResultSHA256 else {
            throw DiagnosticRecordDecodeError.invalidAIEvidenceMetadata(id)
        }
    }
}

enum DiagnosticRecordPayloadDecoder {
    static func withBoundedUTF8Bytes<Value>(
        _ value: String,
        recordIdentifier: String,
        limit: Int,
        consume: (String.UTF8View) throws -> Value
    ) throws -> Value {
        let utf8 = value.utf8
        let byteCount = utf8.count
        guard byteCount <= limit else {
            throw DiagnosticRecordDecodeError.oversized(recordIdentifier, byteCount, limit)
        }
        return try consume(utf8)
    }

    static func boundedUTF8Data(
        _ value: String,
        recordIdentifier: String,
        limit: Int
    ) throws -> Data {
        try withBoundedUTF8Bytes(
            value,
            recordIdentifier: recordIdentifier,
            limit: limit,
            consume: { Data($0) }
        )
    }
}

enum DiagnosticRecordDecodeOutcome: Sendable {
    case success(snapshot: DiagnosticRecordDecodeSnapshot, result: DiagnosticResult)
    case failure(snapshot: DiagnosticRecordDecodeSnapshot, error: DiagnosticRecordDecodeError)

    var snapshot: DiagnosticRecordDecodeSnapshot {
        switch self {
        case .success(let snapshot, _), .failure(let snapshot, _):
            snapshot
        }
    }
}

enum DiagnosticPresentationDecodePipeline {
    private struct IndexedOutcome: Sendable {
        let index: Int
        let outcome: DiagnosticRecordDecodeOutcome
    }

    static func decode(
        _ snapshots: [DiagnosticRecordDecodeSnapshot],
        maxConcurrent: Int = DiagnosticPresentationLimits.concurrentDecodes,
        operation: @escaping @Sendable (DiagnosticRecordDecodeSnapshot) async throws -> DiagnosticRecordDecodeOutcome = {
            snapshot in
            do {
                return .success(snapshot: snapshot, result: try snapshot.requiredDecodedResult())
            } catch let error as DiagnosticRecordDecodeError {
                return .failure(snapshot: snapshot, error: error)
            } catch {
                return .failure(snapshot: snapshot, error: .decodeFailed(snapshot.id))
            }
        }
    ) async throws -> [DiagnosticRecordDecodeOutcome] {
        try Task.checkCancellation()
        guard !snapshots.isEmpty else { return [] }

        let workerCount = min(max(1, maxConcurrent), snapshots.count)
        return try await withThrowingTaskGroup(of: IndexedOutcome.self) { group in
            var nextIndex = 0
            var ordered = Array<DiagnosticRecordDecodeOutcome?>(
                repeating: nil,
                count: snapshots.count
            )

            func submit(_ index: Int) {
                let snapshot = snapshots[index]
                group.addTask {
                    try Task.checkCancellation()
                    let outcome = try await operation(snapshot)
                    try Task.checkCancellation()
                    return IndexedOutcome(index: index, outcome: outcome)
                }
            }

            for _ in 0..<workerCount {
                submit(nextIndex)
                nextIndex += 1
            }

            while let indexed = try await group.next() {
                try Task.checkCancellation()
                ordered[indexed.index] = indexed.outcome
                if nextIndex < snapshots.count {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }

            try Task.checkCancellation()
            return ordered.compactMap { $0 }
        }
    }
}

extension DiagnosticRecord {
    func decodeSnapshot() -> DiagnosticRecordDecodeSnapshot {
        DiagnosticRecordDecodeSnapshot(record: self)
    }

    func requiredDecodedResult() throws -> DiagnosticResult {
        try decodeSnapshot().requiredDecodedResult()
    }

    var decodedResult: DiagnosticResult? {
        try? requiredDecodedResult()
    }
}

@Model
final class CompatibilityRecipeRecord {
    @Attribute(.unique) var recipeId: String
    var steamAppId: String?
    var name: String
    var supportStatus: String
    var confidence: Double
    var recipeJSON: String
    var lastVerifiedAt: Date?

    init(
        recipeId: String,
        steamAppId: String?,
        name: String,
        supportStatus: String,
        confidence: Double,
        recipeJSON: String,
        lastVerifiedAt: Date? = nil
    ) {
        self.recipeId = recipeId
        self.steamAppId = steamAppId
        self.name = name
        self.supportStatus = supportStatus
        self.confidence = confidence
        self.recipeJSON = recipeJSON
        self.lastVerifiedAt = lastVerifiedAt
    }
}

struct CompatibilityRecipeSnapshotApplicationResult: Hashable {
    var insertedCount: Int
    var updatedCount: Int
    var removedRecipeIDs: [String]
}

enum CompatibilityRecipeSnapshotApplicationError: LocalizedError, Equatable {
    case duplicateStoredRecipe(String)
    case duplicateIncomingRecipe(String)

    var errorDescription: String? {
        switch self {
        case .duplicateStoredRecipe(let id):
            "저장된 호환성 정보 ID가 중복되었습니다: \(id)"
        case .duplicateIncomingRecipe(let id):
            "업데이트 호환성 정보 ID가 중복되었습니다: \(id)"
        }
    }
}

extension ModelContext {
    @discardableResult
    func applyCompatibilityRecipeSnapshot(
        _ incomingRecords: [CompatibilityRecipeRecord]
    ) throws -> CompatibilityRecipeSnapshotApplicationResult {
        let storedRecords = try fetch(FetchDescriptor<CompatibilityRecipeRecord>())
        var storedByID: [String: CompatibilityRecipeRecord] = [:]
        for record in storedRecords {
            guard storedByID[record.recipeId] == nil else {
                throw CompatibilityRecipeSnapshotApplicationError.duplicateStoredRecipe(record.recipeId)
            }
            storedByID[record.recipeId] = record
        }

        var incomingByID: [String: CompatibilityRecipeRecord] = [:]
        for record in incomingRecords {
            guard incomingByID[record.recipeId] == nil else {
                throw CompatibilityRecipeSnapshotApplicationError.duplicateIncomingRecipe(record.recipeId)
            }
            incomingByID[record.recipeId] = record
        }

        var insertedCount = 0
        var updatedCount = 0
        for record in incomingByID.values {
            if let stored = storedByID[record.recipeId] {
                CompatibilityRecipeRecordProjection.update(stored, from: record)
                updatedCount += 1
            } else {
                insert(record)
                insertedCount += 1
            }
        }

        let removedRecipeIDs = storedByID.keys
            .filter { incomingByID[$0] == nil }
            .sorted()
        for id in removedRecipeIDs {
            if let stored = storedByID[id] {
                delete(stored)
            }
        }
        return CompatibilityRecipeSnapshotApplicationResult(
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            removedRecipeIDs: removedRecipeIDs
        )
    }
}

@Model
final class AutoFixRecord {
    @Attribute(.unique) var id: String
    var diagnosticId: String
    var actionType: String
    var status: String
    var snapshotPath: String?
    var logPath: String?
    var createdAt: Date

    init(
        id: String = "autofix-\(UUID().uuidString)",
        diagnosticId: String,
        actionType: RecommendedActionType,
        status: String,
        snapshotPath: String? = nil,
        logPath: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.diagnosticId = diagnosticId
        self.actionType = actionType.rawValue
        self.status = status
        self.snapshotPath = snapshotPath
        self.logPath = logPath
        self.createdAt = createdAt
    }
}
