import Foundation
import SwiftData

struct CompatibilitySteamLaunchLegacySnapshotSourceVersionV1: Hashable, Sendable {
    let payloadDigest: String
    let generation: Int64
    let persistenceRevision: UUID

    init(
        payloadDigest: String,
        generation: Int64,
        persistenceRevision: UUID
    ) throws {
        guard SteamLaunchIdentifierValidation.isValidLowercaseSHA256(payloadDigest),
              generation == 0,
              persistenceRevision.uuidString.lowercased() !=
                "00000000-0000-0000-0000-000000000000" else {
            throw SteamCompatibilityLaunchProfileErrorV1.migrationRejected(
                "legacy-source-version"
            )
        }
        self.payloadDigest = payloadDigest
        self.generation = generation
        self.persistenceRevision = persistenceRevision
    }
}

struct CompatibilitySteamLaunchLegacySnapshotV1: Hashable, Sendable {
    let snapshot: SteamLaunchConfigurationSnapshot
    let sourceVersion: CompatibilitySteamLaunchLegacySnapshotSourceVersionV1
}

struct CompatibilitySteamLaunchPreferenceRecoveryVersionV1:
    Hashable, Sendable
{
    let payloadDigest: String
    let generation: Int64
    let persistenceRevision: UUID

    init(
        payloadDigest: String,
        generation: Int64,
        persistenceRevision: UUID
    ) {
        self.payloadDigest = payloadDigest
        self.generation = generation
        self.persistenceRevision = persistenceRevision
    }
}

extension CompatibilitySteamLaunchPreferencePayloadV1 {
    func snapshotV1Projection() throws -> SteamLaunchConfigurationSnapshot {
        try validate()
        return try SteamLaunchConfigurationSnapshot(
            identity: .compatibility(identity),
            graphicsBackend: selections.graphicsBackend,
            networkPolicy: selections.networkPolicy,
            audioInputPolicy: selections.audioInputPolicy,
            synchronizationPolicy: selections.synchronizationPolicy,
            videoMemoryPolicy: selections.videoMemoryPolicy,
            frameGenerationConfiguration: selections.frameGenerationConfiguration,
            gameModeEnabled: selections.gameModeEnabled,
            fpsCursorPolicy: selections.fpsCursorPolicy,
            controllerPolicy: selections.controllerPolicy,
            keyboardMapping: selections.keyboardMapping
        )
    }
}

extension CompatibilitySteamLaunchPreferenceRecord {
    convenience init(
        preference: CompatibilitySteamLaunchPreferencePayloadV1,
        now: Date = Date()
    ) throws {
        let projection = try Self.compatibilityPreferenceProjection(preference)
        try self.init(snapshot: preference.snapshotV1Projection(), now: now)
        schemaVersion = projection.schemaVersion
        canonicalPreferencePayload = projection.payload
        preferenceDigest = projection.digest
        generation = 1
        _ = try CompatibilitySteamLaunchPreferenceEnvelopeV1(
            payload: preference,
            payloadDigest: projection.digest,
            generation: 1,
            persistenceRevision: persistenceRevision,
            createdAt: now,
            updatedAt: now
        )
    }

    func decodedCompatibilityPreferenceEnvelopeV1()
        throws -> CompatibilitySteamLaunchPreferenceEnvelopeV1
    {
        let decoded = try decodedCompatibilityPreferencePayloadAllowingLegacyV1()
        guard decoded.sourceSchemaVersion ==
                SteamCompatibilityLaunchProfileContractV1.preferenceSchemaVersion else {
            throw SteamLaunchConfigurationPersistenceError.schemaVersionMismatch(
                stored: schemaVersion,
                decoded: SteamCompatibilityLaunchProfileContractV1.preferenceSchemaVersion
            )
        }
        return try CompatibilitySteamLaunchPreferenceEnvelopeV1(
            payload: decoded.preference,
            payloadDigest: preferenceDigest,
            generation: generation,
            persistenceRevision: persistenceRevision,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Rewrites an already-deployed generation-1+ preference payload from the
    /// legacy v1 canonical schema to the current schema without changing any
    /// user selection. The CAS generation and revision advance atomically so a
    /// stale window cannot save through the migration.
    func migrateCompatibilityPreferencePayloadSchemaV1(now: Date) throws {
        let decoded = try decodedCompatibilityPreferencePayloadAllowingLegacyV1()
        guard generation > 0,
              decoded.sourceSchemaVersion ==
                SteamCompatibilityLaunchProfileContractV1.legacyPreferenceSchemaVersion else {
            throw SteamCompatibilityLaunchProfileErrorV1.migrationRejected(
                "preference-payload-schema-source"
            )
        }
        guard generation < Int64.max else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidPreference(
                "generation-overflow"
            )
        }
        guard now >= createdAt else {
            throw SteamCompatibilityLaunchProfileErrorV1.migrationRejected(
                "preference-payload-schema-timestamp"
            )
        }

        let projection = try Self.compatibilityPreferenceProjection(decoded.preference)
        let nextGeneration = generation + 1
        let nextRevision = Self.makeCompatibilityPreferenceRevisionV1(
            excluding: persistenceRevision
        )
        _ = try CompatibilitySteamLaunchPreferenceEnvelopeV1(
            payload: decoded.preference,
            payloadDigest: projection.digest,
            generation: nextGeneration,
            persistenceRevision: nextRevision,
            createdAt: createdAt,
            updatedAt: now
        )

        schemaVersion = projection.schemaVersion
        canonicalPreferencePayload = projection.payload
        preferenceDigest = projection.digest
        generation = nextGeneration
        persistenceRevision = nextRevision
        updatedAt = now
    }

    func decodedCompatibilityLegacySnapshotV1()
        throws -> CompatibilitySteamLaunchLegacySnapshotV1
    {
        let snapshot = try decodedSnapshot()
        let sourceVersion = try CompatibilitySteamLaunchLegacySnapshotSourceVersionV1(
            payloadDigest: preferenceDigest,
            generation: generation,
            persistenceRevision: persistenceRevision
        )
        return CompatibilitySteamLaunchLegacySnapshotV1(
            snapshot: snapshot,
            sourceVersion: sourceVersion
        )
    }

    func replaceCompatibilityPreferenceV1(
        with preference: CompatibilitySteamLaunchPreferencePayloadV1,
        now: Date
    ) throws {
        let projection = try Self.compatibilityPreferenceProjection(preference)
        guard id == preference.identity.deterministicRecordID,
              steamAppID == preference.identity.steamAppID,
              profileID == preference.identity.profileID,
              recipeRevision == preference.identity.recipeRevision else {
            throw SteamLaunchConfigurationPersistenceError.recordIdentityMismatch(
                "compatibility-v1-replacement-target"
            )
        }
        let current = try decodedCompatibilityPreferenceEnvelopeV1()
        guard current.generation < Int64.max else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidPreference(
                "generation-overflow"
            )
        }
        let nextGeneration = current.generation + 1
        let nextRevision = Self.makeCompatibilityPreferenceRevisionV1(
            excluding: persistenceRevision
        )
        _ = try CompatibilitySteamLaunchPreferenceEnvelopeV1(
            payload: preference,
            payloadDigest: projection.digest,
            generation: nextGeneration,
            persistenceRevision: nextRevision,
            createdAt: createdAt,
            updatedAt: now
        )

        schemaVersion = projection.schemaVersion
        canonicalPreferencePayload = projection.payload
        preferenceDigest = projection.digest
        generation = nextGeneration
        persistenceRevision = nextRevision
        updatedAt = now
    }

    func migrateCompatibilityLegacySnapshotV1(
        to preference: CompatibilitySteamLaunchPreferencePayloadV1,
        expectedSourceVersion: CompatibilitySteamLaunchLegacySnapshotSourceVersionV1,
        now: Date
    ) throws {
        let current = try decodedCompatibilityLegacySnapshotV1()
        guard current.sourceVersion == expectedSourceVersion else {
            throw SteamLaunchConfigurationPersistenceError.writeConflict(
                type: "compatibility-legacy-v1",
                id: id
            )
        }
        let projection = try Self.compatibilityPreferenceProjection(preference)
        guard id == preference.identity.deterministicRecordID,
              steamAppID == preference.identity.steamAppID,
              profileID == preference.identity.profileID,
              recipeRevision == preference.identity.recipeRevision else {
            throw SteamLaunchConfigurationPersistenceError.recordIdentityMismatch(
                "compatibility-v1-migration-target"
            )
        }
        guard now >= createdAt else {
            throw SteamCompatibilityLaunchProfileErrorV1.migrationRejected(
                "migration-timestamp"
            )
        }
        let nextRevision = Self.makeCompatibilityPreferenceRevisionV1(
            excluding: persistenceRevision
        )
        _ = try CompatibilitySteamLaunchPreferenceEnvelopeV1(
            payload: preference,
            payloadDigest: projection.digest,
            generation: 1,
            persistenceRevision: nextRevision,
            createdAt: createdAt,
            updatedAt: now
        )

        schemaVersion = projection.schemaVersion
        canonicalPreferencePayload = projection.payload
        preferenceDigest = projection.digest
        generation = 1
        persistenceRevision = nextRevision
        updatedAt = now
    }

    fileprivate static func compatibilityPreferenceProjection(
        _ preference: CompatibilitySteamLaunchPreferencePayloadV1
    ) throws -> (schemaVersion: Int, payload: Data, digest: String) {
        try preference.validate()
        let payload = try preference.canonicalPayload()
        let decoded = try CompatibilitySteamLaunchPreferencePayloadV1(
            canonicalPayload: payload
        )
        guard decoded == preference else {
            throw SteamCompatibilityLaunchProfileErrorV1.invalidPreference(
                "canonical-round-trip"
            )
        }
        return (preference.schemaVersion, payload, try preference.canonicalDigest)
    }

    fileprivate static func makeCompatibilityPreferenceRevisionV1(
        excluding existing: UUID
    ) -> UUID {
        while true {
            let candidate = UUID()
            if candidate != existing,
               candidate.uuidString.lowercased() !=
                "00000000-0000-0000-0000-000000000000" {
                return candidate
            }
        }
    }

    private func decodedCompatibilityPreferencePayloadAllowingLegacyV1() throws -> (
        preference: CompatibilitySteamLaunchPreferencePayloadV1,
        sourceSchemaVersion: Int
    ) {
        guard generation > 0 else {
            throw SteamCompatibilityLaunchProfileErrorV1.migrationRejected(
                "preference-generation"
            )
        }
        guard persistenceRevision.uuidString.lowercased() !=
            "00000000-0000-0000-0000-000000000000" else {
            throw SteamLaunchConfigurationPersistenceError.invalidPersistenceRevision(
                persistenceRevision
            )
        }
        guard preferenceDigest == SteamLaunchIdentifierValidation.lowercaseSHA256(
            canonicalPreferencePayload
        ) else {
            throw SteamLaunchConfigurationPersistenceError.digestMismatch
        }
        guard let sourceSchemaVersion = CompatibilitySteamLaunchPreferencePayloadV1
            .canonicalPayloadSchemaVersion(canonicalPreferencePayload),
              schemaVersion == sourceSchemaVersion else {
            throw SteamLaunchConfigurationPersistenceError.schemaVersionMismatch(
                stored: schemaVersion,
                decoded: CompatibilitySteamLaunchPreferencePayloadV1
                    .canonicalPayloadSchemaVersion(canonicalPreferencePayload) ?? -1
            )
        }
        let preference = try CompatibilitySteamLaunchPreferencePayloadV1(
            canonicalPayload: canonicalPreferencePayload
        )
        guard id == preference.identity.deterministicRecordID else {
            throw SteamLaunchConfigurationPersistenceError.recordIdentityMismatch(
                "compatibility-v1-record-id"
            )
        }
        guard steamAppID == preference.identity.steamAppID,
              profileID == preference.identity.profileID,
              recipeRevision == preference.identity.recipeRevision else {
            throw SteamLaunchConfigurationPersistenceError.recordIdentityMismatch(
                "compatibility-v1-identity-columns"
            )
        }
        return (preference, sourceSchemaVersion)
    }
}

@MainActor
struct CompatibilitySteamLaunchPreferenceRepositoryV1 {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(
        identity: SteamCompatibilityProfileIdentity
    ) throws -> CompatibilitySteamLaunchPreferenceEnvelopeV1? {
        let context = makeContext()
        do {
            guard let record = try fetch(identity: identity, in: context) else {
                return nil
            }
            try migratePreferencePayloadSchemaIfRequired(record, now: Date())
            if context.hasChanges {
                try context.saveOrRollback()
            }
            return try record.decodedCompatibilityPreferenceEnvelopeV1()
        } catch {
            if context.hasChanges {
                context.rollback()
            }
            throw error
        }
    }

    /// Loads the current envelope or atomically migrates an exact generation-0
    /// snapshot while its persistence revision is still the one observed in
    /// this transaction. A current record is never rewritten by this path.
    func loadOrMigrate(
        recipe: SteamCompatibilityLaunchProfileRecipeV1,
        now: Date = Date()
    ) throws -> CompatibilitySteamLaunchPreferenceEnvelopeV1? {
        try recipe.validate()
        let context = makeContext()
        do {
            guard let record = try fetch(identity: recipe.identity, in: context) else {
                return nil
            }
            guard record.generation == 0 else {
                try migratePreferencePayloadSchemaIfRequired(record, now: now)
                if context.hasChanges {
                    try context.saveOrRollback()
                }
                return try record.decodedCompatibilityPreferenceEnvelopeV1()
            }
            let legacy = try record.decodedCompatibilityLegacySnapshotV1()
            let preference = try SteamCompatibilitySnapshotV1MigrationAdapter.preference(
                from: legacy.snapshot,
                recipe: recipe
            )
            try record.migrateCompatibilityLegacySnapshotV1(
                to: preference,
                expectedSourceVersion: legacy.sourceVersion,
                now: now
            )
            try context.saveOrRollback()
            return try record.decodedCompatibilityPreferenceEnvelopeV1()
        } catch {
            if context.hasChanges {
                context.rollback()
            }
            throw error
        }
    }

    func loadLegacySnapshotV1(
        identity: SteamCompatibilityProfileIdentity
    ) throws -> CompatibilitySteamLaunchLegacySnapshotV1? {
        let context = makeContext()
        guard let record = try fetch(identity: identity, in: context),
              record.generation == 0 else {
            return nil
        }
        return try record.decodedCompatibilityLegacySnapshotV1()
    }

    func recoveryVersion(
        identity: SteamCompatibilityProfileIdentity
    ) throws -> CompatibilitySteamLaunchPreferenceRecoveryVersionV1? {
        let context = makeContext()
        guard let record = try fetch(identity: identity, in: context) else {
            return nil
        }
        try validateRecoveryIdentity(record, expected: identity)
        return recoveryVersion(from: record)
    }

    func resetForRecovery(
        identity: SteamCompatibilityProfileIdentity,
        expectedVersion: CompatibilitySteamLaunchPreferenceRecoveryVersionV1
    ) throws {
        let context = makeContext()
        do {
            guard let record = try fetch(identity: identity, in: context) else {
                throw conflict(for: identity)
            }
            try validateRecoveryIdentity(record, expected: identity)
            guard recoveryVersion(from: record) == expectedVersion else {
                throw conflict(for: identity)
            }
            context.delete(record)
            try context.saveOrRollback()
        } catch {
            if context.hasChanges { context.rollback() }
            throw error
        }
    }

    @discardableResult
    func save(
        _ preference: CompatibilitySteamLaunchPreferencePayloadV1,
        expectedSourceVersion: CompatibilitySteamLaunchPreferenceSourceVersionV1?,
        now: Date = Date()
    ) throws -> CompatibilitySteamLaunchPreferenceEnvelopeV1 {
        try preference.validate()
        _ = try preference.canonicalPayload()
        _ = try preference.canonicalDigest

        let context = makeContext()
        do {
            let existing = try fetch(identity: preference.identity, in: context)
            let record: CompatibilitySteamLaunchPreferenceRecord
            if let existing {
                try migratePreferencePayloadSchemaIfRequired(existing, now: now)
                let current = try existing.decodedCompatibilityPreferenceEnvelopeV1()
                guard let expectedSourceVersion,
                      expectedSourceVersion == current.sourceVersion else {
                    throw conflict(for: preference.identity)
                }
                try existing.replaceCompatibilityPreferenceV1(
                    with: preference,
                    now: now
                )
                record = existing
            } else {
                guard expectedSourceVersion == nil else {
                    throw conflict(for: preference.identity)
                }
                record = try CompatibilitySteamLaunchPreferenceRecord(
                    preference: preference,
                    now: now
                )
                context.insert(record)
            }
            try context.saveOrRollback()
            return try record.decodedCompatibilityPreferenceEnvelopeV1()
        } catch {
            if context.hasChanges {
                context.rollback()
            }
            throw error
        }
    }

    @discardableResult
    func migrateSnapshotV1(
        recipe: SteamCompatibilityLaunchProfileRecipeV1,
        expectedSourceVersion: CompatibilitySteamLaunchLegacySnapshotSourceVersionV1,
        now: Date = Date()
    ) throws -> CompatibilitySteamLaunchPreferenceEnvelopeV1 {
        try recipe.validate()
        let context = makeContext()
        do {
            guard let existing = try fetch(identity: recipe.identity, in: context) else {
                throw conflict(for: recipe.identity)
            }
            guard existing.generation == 0 else {
                throw conflict(for: recipe.identity)
            }
            let legacy = try existing.decodedCompatibilityLegacySnapshotV1()
            guard legacy.sourceVersion == expectedSourceVersion else {
                throw conflict(for: recipe.identity)
            }
            let preference = try SteamCompatibilitySnapshotV1MigrationAdapter.preference(
                from: legacy.snapshot,
                recipe: recipe
            )
            try existing.migrateCompatibilityLegacySnapshotV1(
                to: preference,
                expectedSourceVersion: expectedSourceVersion,
                now: now
            )
            try context.saveOrRollback()
            return try existing.decodedCompatibilityPreferenceEnvelopeV1()
        } catch {
            if context.hasChanges {
                context.rollback()
            }
            throw error
        }
    }

    func delete(
        identity: SteamCompatibilityProfileIdentity,
        expectedSourceVersion: CompatibilitySteamLaunchPreferenceSourceVersionV1
    ) throws {
        let context = makeContext()
        do {
            guard let existing = try fetch(identity: identity, in: context) else {
                throw conflict(for: identity)
            }
            try migratePreferencePayloadSchemaIfRequired(existing, now: Date())
            let current = try existing.decodedCompatibilityPreferenceEnvelopeV1()
            guard current.sourceVersion == expectedSourceVersion else {
                throw conflict(for: identity)
            }
            context.delete(existing)
            try context.saveOrRollback()
        } catch {
            if context.hasChanges {
                context.rollback()
            }
            throw error
        }
    }

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func migratePreferencePayloadSchemaIfRequired(
        _ record: CompatibilitySteamLaunchPreferenceRecord,
        now: Date
    ) throws {
        guard record.generation > 0,
              record.schemaVersion ==
                SteamCompatibilityLaunchProfileContractV1.legacyPreferenceSchemaVersion else {
            return
        }
        try record.migrateCompatibilityPreferencePayloadSchemaV1(now: now)
    }

    private func fetch(
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
                type: "compatibility-v1",
                id: recordID
            )
        }
        return matches.first
    }

    private func validateRecoveryIdentity(
        _ record: CompatibilitySteamLaunchPreferenceRecord,
        expected identity: SteamCompatibilityProfileIdentity
    ) throws {
        guard record.id == identity.deterministicRecordID,
              record.steamAppID == identity.steamAppID,
              record.profileID == identity.profileID,
              record.recipeRevision == identity.recipeRevision else {
            throw SteamLaunchConfigurationPersistenceError.recordIdentityMismatch(
                "compatibility-v1-recovery-identity"
            )
        }
    }

    private func recoveryVersion(
        from record: CompatibilitySteamLaunchPreferenceRecord
    ) -> CompatibilitySteamLaunchPreferenceRecoveryVersionV1 {
        CompatibilitySteamLaunchPreferenceRecoveryVersionV1(
            payloadDigest: record.preferenceDigest,
            generation: record.generation,
            persistenceRevision: record.persistenceRevision
        )
    }

    private func conflict(
        for identity: SteamCompatibilityProfileIdentity
    ) -> SteamLaunchConfigurationPersistenceError {
        .writeConflict(
            type: "compatibility-v1",
            id: identity.deterministicRecordID
        )
    }
}
