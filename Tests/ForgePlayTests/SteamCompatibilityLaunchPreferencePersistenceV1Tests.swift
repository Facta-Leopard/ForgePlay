import Foundation
import SwiftData
import XCTest
@testable import ForgePlay

@MainActor
final class SteamCompatibilityLaunchPreferencePersistenceV1Tests: XCTestCase {
    private let recipe = SteamCompatibilityLaunchProfileCatalogV1.helldivers2

    func testCorruptPreferenceHasExplicitCASTokenRecoveryReset() throws {
        let container = try makeContainer()
        let repository = CompatibilitySteamLaunchPreferenceRepositoryV1(
            container: container
        )
        _ = try repository.save(
            preference(),
            expectedSourceVersion: nil
        )
        let corruptionContext = ModelContext(container)
        corruptionContext.autosaveEnabled = false
        let record = try XCTUnwrap(
            corruptionContext.fetch(
                FetchDescriptor<CompatibilitySteamLaunchPreferenceRecord>()
            ).first
        )
        record.canonicalPreferencePayload.append(0)
        try corruptionContext.save()

        XCTAssertThrowsError(try repository.loadOrMigrate(recipe: recipe))
        let recoveryVersion = try XCTUnwrap(
            repository.recoveryVersion(identity: recipe.identity)
        )
        try repository.resetForRecovery(
            identity: recipe.identity,
            expectedVersion: recoveryVersion
        )
        XCTAssertNil(try repository.recoveryVersion(identity: recipe.identity))
        XCTAssertNil(try repository.loadOrMigrate(recipe: recipe))
    }

    func testCreateAndReplacementUseExpectedSourceVersionAndIncrementGenerationExactlyOnce() throws {
        let container = try makeContainer()
        let repository = CompatibilitySteamLaunchPreferenceRepositoryV1(container: container)
        let createdAt = Date(timeIntervalSinceReferenceDate: 100)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 200)
        let initial = try preference()

        let created = try repository.save(
            initial,
            expectedSourceVersion: nil,
            now: createdAt
        )
        XCTAssertEqual(created.generation, 1)
        XCTAssertEqual(created.createdAt, createdAt)
        XCTAssertEqual(created.updatedAt, createdAt)

        var changedSelections = initial.selections
        changedSelections.gameModeEnabled = false
        changedSelections.heapZeroMemoryEnabled = false
        let changed = try CompatibilitySteamLaunchPreferencePayloadV1(
            identity: recipe.identity,
            selections: changedSelections
        )
        let replaced = try repository.save(
            changed,
            expectedSourceVersion: created.sourceVersion,
            now: updatedAt
        )

        XCTAssertEqual(replaced.generation, 2)
        XCTAssertEqual(replaced.createdAt, createdAt)
        XCTAssertEqual(replaced.updatedAt, updatedAt)
        XCTAssertFalse(replaced.payload.selections.gameModeEnabled)
        XCTAssertFalse(replaced.payload.selections.heapZeroMemoryEnabled)
    }

    func testStaleAndMissingExpectedSourceVersionsConflictWithoutMutation() throws {
        let container = try makeContainer()
        let repository = CompatibilitySteamLaunchPreferenceRepositoryV1(container: container)
        let created = try repository.save(
            preference(),
            expectedSourceVersion: nil,
            now: Date(timeIntervalSinceReferenceDate: 100)
        )
        var changedSelections = created.payload.selections
        changedSelections.gameModeEnabled.toggle()
        let changed = try CompatibilitySteamLaunchPreferencePayloadV1(
            identity: recipe.identity,
            selections: changedSelections
        )

        XCTAssertThrowsError(try repository.save(changed, expectedSourceVersion: nil))
        XCTAssertThrowsError(
            try repository.save(
                changed,
                expectedSourceVersion: CompatibilitySteamLaunchPreferenceSourceVersionV1(
                    payloadDigest: String(repeating: "0", count: 64),
                    generation: created.generation,
                    persistenceRevision: created.persistenceRevision
                )
            )
        )

        let after = try XCTUnwrap(repository.load(identity: recipe.identity))
        XCTAssertEqual(after, created)
    }

    func testCompatibilitySaveDoesNotMutateStandardRecord() throws {
        let container = try makeContainer()
        let standardRepository = SteamLaunchConfigurationRepository(container: container)
        let standard = try standardRepository.saveStandard(
            .standardDefault,
            expectedVersion: nil,
            now: Date(timeIntervalSinceReferenceDate: 50)
        )

        let compatibilityRepository = CompatibilitySteamLaunchPreferenceRepositoryV1(
            container: container
        )
        _ = try compatibilityRepository.save(
            preference(),
            expectedSourceVersion: nil,
            now: Date(timeIntervalSinceReferenceDate: 100)
        )

        let standardAfter = try XCTUnwrap(standardRepository.loadStandard())
        XCTAssertEqual(standardAfter, standard)
    }

    func testStandardAndCompatibilityRendererAndGameModeRemainExactInBothSaveOrders()
        throws
    {
        for standardFirst in [true, false] {
            let container = try makeContainer()
            let standardRepository = SteamLaunchConfigurationRepository(container: container)
            let compatibilityRepository = CompatibilitySteamLaunchPreferenceRepositoryV1(
                container: container
            )
            let standardSnapshot = try SteamLaunchConfigurationSnapshot(
                identity: .standard,
                graphicsBackend: .dxmt,
                gameModeEnabled: false
            )
            var compatibilitySelections = recipe.initialSelections
            compatibilitySelections.graphicsBackend = .dxvk
            compatibilitySelections.gameModeEnabled = true
            let compatibilityPreference = try CompatibilitySteamLaunchPreferencePayloadV1(
                identity: recipe.identity,
                selections: compatibilitySelections
            )

            if standardFirst {
                _ = try standardRepository.saveStandard(
                    standardSnapshot,
                    expectedVersion: nil
                )
                _ = try compatibilityRepository.save(
                    compatibilityPreference,
                    expectedSourceVersion: nil
                )
            } else {
                _ = try compatibilityRepository.save(
                    compatibilityPreference,
                    expectedSourceVersion: nil
                )
                _ = try standardRepository.saveStandard(
                    standardSnapshot,
                    expectedVersion: nil
                )
            }

            let loadedStandard = try XCTUnwrap(standardRepository.loadStandard())
            let loadedCompatibility = try XCTUnwrap(
                compatibilityRepository.load(identity: recipe.identity)
            )
            XCTAssertEqual(loadedStandard.snapshot.graphicsBackend, .dxmt)
            XCTAssertFalse(loadedStandard.snapshot.gameModeEnabled)
            XCTAssertEqual(
                loadedCompatibility.payload.selections.graphicsBackend,
                .dxvk
            )
            XCTAssertTrue(loadedCompatibility.payload.selections.gameModeEnabled)
        }
    }

    func testEveryNetworkAudioAndVideoMemoryCombinationReloadsWithoutStandardMixing()
        throws
    {
        let container = try makeContainer()
        let standardRepository = SteamLaunchConfigurationRepository(container: container)
        let compatibilityRepository = CompatibilitySteamLaunchPreferenceRepositoryV1(
            container: container
        )
        let standardSnapshot = try SteamLaunchConfigurationSnapshot(
            identity: .standard,
            graphicsBackend: .d9vk,
            networkPolicy: .ethernetIdentity,
            audioInputPolicy: .enabled,
            synchronizationPolicy: .automatic,
            videoMemoryPolicy: .gb16,
            gameModeEnabled: false
        )
        let storedStandard = try standardRepository.saveStandard(
            standardSnapshot,
            expectedVersion: nil
        )
        var expectedSourceVersion: CompatibilitySteamLaunchPreferenceSourceVersionV1?

        for networkPolicy in recipe.supportedOptions.networkPolicies {
            for audioInputPolicy in recipe.supportedOptions.audioInputPolicies {
                for videoMemoryPolicy in recipe.supportedOptions.videoMemoryPolicies {
                    var selections = recipe.initialSelections
                    selections.graphicsBackend = .dxvk
                    selections.networkPolicy = networkPolicy
                    selections.audioInputPolicy = audioInputPolicy
                    selections.videoMemoryPolicy = videoMemoryPolicy
                    selections.gameModeEnabled = true
                    selections.heapZeroMemoryEnabled = false
                    let payload = try CompatibilitySteamLaunchPreferencePayloadV1(
                        identity: recipe.identity,
                        selections: selections
                    )

                    let stored = try compatibilityRepository.save(
                        payload,
                        expectedSourceVersion: expectedSourceVersion
                    )
                    expectedSourceVersion = stored.sourceVersion
                    let reloaded = try XCTUnwrap(
                        compatibilityRepository.load(identity: recipe.identity)
                    )

                    XCTAssertEqual(reloaded, stored)
                    XCTAssertEqual(reloaded.payload, payload)
                    XCTAssertEqual(reloaded.payload.selections.networkPolicy, networkPolicy)
                    XCTAssertEqual(
                        reloaded.payload.selections.audioInputPolicy,
                        audioInputPolicy
                    )
                    XCTAssertEqual(
                        reloaded.payload.selections.videoMemoryPolicy,
                        videoMemoryPolicy
                    )
                    XCTAssertEqual(
                        try standardRepository.loadStandard(),
                        storedStandard
                    )
                }
            }
        }

        XCTAssertEqual(expectedSourceVersion?.generation, 36)
    }

    func testExactProfileFetchDoesNotReadOrMutateAnotherProfile() throws {
        let container = try makeContainer()
        let repository = CompatibilitySteamLaunchPreferenceRepositoryV1(container: container)
        let first = try repository.save(preference(), expectedSourceVersion: nil)
        let otherIdentity = try SteamCompatibilityProfileIdentity(
            steamAppID: "553851",
            profileID: "forgeplay.other.compatibility",
            recipeRevision: "v1"
        )
        let otherPayload = try CompatibilitySteamLaunchPreferencePayloadV1(
            identity: otherIdentity,
            selections: recipe.initialSelections
        )
        let other = try repository.save(otherPayload, expectedSourceVersion: nil)

        XCTAssertEqual(
            try repository.load(identity: recipe.identity),
            first
        )
        XCTAssertEqual(
            try repository.load(identity: otherIdentity),
            other
        )
    }

    func testSnapshotMigrationAtomicallyReplacesAnExactLegacyGenerationZeroRecord() throws {
        let container = try makeContainer()
        let repository = CompatibilitySteamLaunchPreferenceRepositoryV1(container: container)
        let legacyRepository = SteamLaunchConfigurationRepository(container: container)
        let createdAt = Date(timeIntervalSinceReferenceDate: 100)
        let migratedAt = Date(timeIntervalSinceReferenceDate: 200)
        let snapshot = try SteamLaunchConfigurationSnapshot(
            identity: .compatibility(recipe.identity),
            graphicsBackend: SteamGraphicsBackendIdentifier.validated("dxmt"),
            networkPolicy: SteamNetworkPolicyIdentifier.validated("wifi-identity"),
            audioInputPolicy: .enabled,
            synchronizationPolicy: .automatic,
            videoMemoryPolicy: SteamVideoMemoryPolicyIdentifier.validated("gb8"),
            gameModeEnabled: false
        )
        let storedLegacy = try legacyRepository.saveCompatibility(
            snapshot,
            expectedVersion: nil,
            now: createdAt
        )
        let legacy = try XCTUnwrap(
            repository.loadLegacySnapshotV1(identity: recipe.identity)
        )
        XCTAssertEqual(legacy.sourceVersion.generation, 0)
        XCTAssertEqual(legacy.sourceVersion.payloadDigest, storedLegacy.version.digest)
        XCTAssertEqual(legacy.sourceVersion.persistenceRevision, storedLegacy.version.revision)

        let migrated = try repository.migrateSnapshotV1(
            recipe: recipe,
            expectedSourceVersion: legacy.sourceVersion,
            now: migratedAt
        )
        XCTAssertEqual(migrated.generation, 1)
        XCTAssertEqual(migrated.createdAt, createdAt)
        XCTAssertEqual(migrated.updatedAt, migratedAt)
        XCTAssertEqual(migrated.payload.selections.graphicsBackend, snapshot.graphicsBackend)
        XCTAssertEqual(
            migrated.payload.selections.heapZeroMemoryEnabled,
            recipe.initialSelections.heapZeroMemoryEnabled
        )
        let observer = ModelContext(container)
        let recordID = recipe.identity.deterministicRecordID
        let records = try observer.fetch(
            FetchDescriptor<CompatibilitySteamLaunchPreferenceRecord>(
                predicate: #Predicate { $0.id == recordID }
            )
        )
        let migratedRecord = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(migratedRecord.generation, 1)
        XCTAssertEqual(migratedRecord.createdAt, createdAt)
        XCTAssertNotEqual(
            migratedRecord.persistenceRevision,
            legacy.sourceVersion.persistenceRevision
        )
        XCTAssertNotEqual(
            migratedRecord.persistenceRevision.uuidString.lowercased(),
            "00000000-0000-0000-0000-000000000000"
        )
        let migratedRecordVersion = try XCTUnwrap(
            repository.load(identity: recipe.identity)
        )
        XCTAssertEqual(migratedRecordVersion, migrated)
        XCTAssertNil(
            try repository.loadLegacySnapshotV1(identity: recipe.identity)
        )
        XCTAssertThrowsError(
            try repository.migrateSnapshotV1(
                recipe: recipe,
                expectedSourceVersion: legacy.sourceVersion
            )
        )
    }

    func testSnapshotMigrationRejectsAStaleExactLegacySourceVersionWithoutMutation() throws {
        let container = try makeContainer()
        let repository = CompatibilitySteamLaunchPreferenceRepositoryV1(container: container)
        let legacyRepository = SteamLaunchConfigurationRepository(container: container)
        let original = try SteamLaunchConfigurationSnapshot(
            identity: .compatibility(recipe.identity),
            graphicsBackend: .d3dMetal
        )
        let storedOriginal = try legacyRepository.saveCompatibility(
            original,
            expectedVersion: nil
        )
        let stale = try XCTUnwrap(
            repository.loadLegacySnapshotV1(identity: recipe.identity)
        )
        let changed = try SteamLaunchConfigurationSnapshot(
            identity: .compatibility(recipe.identity),
            graphicsBackend: SteamGraphicsBackendIdentifier.validated("dxmt")
        )
        _ = try legacyRepository.saveCompatibility(
            changed,
            expectedVersion: storedOriginal.version
        )

        XCTAssertThrowsError(
            try repository.migrateSnapshotV1(
                recipe: recipe,
                expectedSourceVersion: stale.sourceVersion
            )
        )
        let after = try XCTUnwrap(
            repository.loadLegacySnapshotV1(identity: recipe.identity)
        )
        XCTAssertEqual(after.snapshot, changed)
        XCTAssertEqual(after.sourceVersion.generation, 0)
    }

    func testDigestAndGenerationPairRejectsABA() throws {
        let container = try makeContainer()
        let repository = CompatibilitySteamLaunchPreferenceRepositoryV1(container: container)
        let payloadA = try preference()
        let versionA = try repository.save(payloadA, expectedSourceVersion: nil)

        var selectionsB = payloadA.selections
        selectionsB.gameModeEnabled.toggle()
        let payloadB = try CompatibilitySteamLaunchPreferencePayloadV1(
            identity: recipe.identity,
            selections: selectionsB
        )
        let versionB = try repository.save(
            payloadB,
            expectedSourceVersion: versionA.sourceVersion
        )
        let versionAAgain = try repository.save(
            payloadA,
            expectedSourceVersion: versionB.sourceVersion
        )

        XCTAssertEqual(versionAAgain.payloadDigest, versionA.payloadDigest)
        XCTAssertEqual(versionAAgain.generation, 3)
        XCTAssertThrowsError(
            try repository.save(
                payloadB,
                expectedSourceVersion: versionA.sourceVersion
            )
        )
        XCTAssertEqual(
            try repository.load(identity: recipe.identity),
            versionAAgain
        )
    }

    func testDeleteUsesExactSourceVersionAndLeavesStandardUntouched() throws {
        let container = try makeContainer()
        let standardRepository = SteamLaunchConfigurationRepository(container: container)
        let standard = try standardRepository.saveStandard(
            .standardDefault,
            expectedVersion: nil
        )
        let repository = CompatibilitySteamLaunchPreferenceRepositoryV1(container: container)
        let compatibility = try repository.save(
            preference(),
            expectedSourceVersion: nil
        )

        XCTAssertThrowsError(
            try repository.delete(
                identity: recipe.identity,
                expectedSourceVersion: CompatibilitySteamLaunchPreferenceSourceVersionV1(
                    payloadDigest: compatibility.payloadDigest,
                    generation: compatibility.generation + 1,
                    persistenceRevision: compatibility.persistenceRevision
                )
            )
        )
        XCTAssertNotNil(try repository.load(identity: recipe.identity))

        try repository.delete(
            identity: recipe.identity,
            expectedSourceVersion: compatibility.sourceVersion
        )
        XCTAssertNil(try repository.load(identity: recipe.identity))
        XCTAssertEqual(try standardRepository.loadStandard(), standard)
    }

    private func preference() throws -> CompatibilitySteamLaunchPreferencePayloadV1 {
        try CompatibilitySteamLaunchPreferencePayloadV1(
            identity: recipe.identity,
            selections: recipe.initialSelections
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            StandardSteamLaunchConfigurationRecord.self,
            CompatibilitySteamLaunchPreferenceRecord.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
