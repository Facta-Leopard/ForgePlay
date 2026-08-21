import Foundation
import SwiftData
import XCTest
@testable import ForgePlay

@MainActor
final class SteamLaunchConfigurationPersistenceTests: XCTestCase {
    func testExplicitSaveSurvivesFreshPersistentContainerWithoutTerminationCallback() throws {
        let applicationSupport = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlayLaunchConfigurationPersistence-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let snapshot = try SteamLaunchConfigurationSnapshot(
            identity: .standard,
            graphicsBackend: .d3dMetalNVIDIA,
            networkPolicy: .standard,
            audioInputPolicy: .disabled,
            gameModeEnabled: true
        )

        try autoreleasepool {
            let writer = try ForgePlayApp.makeModelContainer(
                applicationSupportDirectory: applicationSupport
            )
            let repository = SteamLaunchConfigurationRepository(container: writer)
            let stored = try repository.saveStandard(
                snapshot,
                expectedVersion: nil
            )
            XCTAssertEqual(stored.snapshot, snapshot)
        }

        try autoreleasepool {
            let reader = try ForgePlayApp.makeModelContainer(
                applicationSupportDirectory: applicationSupport
            )
            let repository = SteamLaunchConfigurationRepository(container: reader)
            XCTAssertEqual(try repository.loadStandard()?.snapshot, snapshot)
        }
    }

    func testStandardRecordUpsertRoundTripPreservesCreationTime() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let createdAt = Date(timeIntervalSince1970: 100)
        let updatedAt = Date(timeIntervalSince1970: 200)
        let original = SteamLaunchConfigurationSnapshot.standardDefault

        let inserted = try context.upsertStandardSteamLaunchConfiguration(
            original,
            now: createdAt
        )
        XCTAssertEqual(try inserted.decodedSnapshot(), original)
        XCTAssertEqual(inserted.createdAt, createdAt)
        XCTAssertEqual(inserted.updatedAt, createdAt)

        let replacement = try SteamLaunchConfigurationSnapshot(
            identity: .standard,
            graphicsBackend: .dxmt,
            gameModeEnabled: false,
            fpsCursorPolicy: .fpsRelativeCaptureBeta,
            controllerPolicy: .automatic,
            keyboardMapping: .windowsFriendly
        )
        let updated = try context.upsertStandardSteamLaunchConfiguration(
            replacement,
            now: updatedAt
        )

        XCTAssertTrue(inserted === updated)
        XCTAssertEqual(try updated.decodedSnapshot(), replacement)
        XCTAssertEqual(updated.createdAt, createdAt)
        XCTAssertEqual(updated.updatedAt, updatedAt)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<StandardSteamLaunchConfigurationRecord>()).count,
            1
        )
    }

    func testCompatibilityPreferenceIsIndependentFromStandardConfiguration() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let standardTime = Date(timeIntervalSince1970: 10)
        let compatibilityTime = Date(timeIntervalSince1970: 20)
        let standard = try context.upsertStandardSteamLaunchConfiguration(
            .standardDefault,
            now: standardTime
        )
        let standardDigest = standard.configurationDigest
        let compatibility = try SteamLaunchConfigurationSnapshot(
            identity: .compatibility(
                SteamCompatibilityProfileIdentity(
                    steamAppID: "553850",
                    profileID: "helldivers-2",
                    recipeRevision: "v1"
                )
            ),
            graphicsBackend: .d3dMetal,
            networkPolicy: .standard,
            audioInputPolicy: .enabled,
            synchronizationPolicy: .automatic,
            videoMemoryPolicy: .automatic,
            gameModeEnabled: true,
            fpsCursorPolicy: .fpsRelativeCaptureBeta,
            controllerPolicy: .automatic,
            keyboardMapping: .windowsFriendly
        )

        let preference = try context.upsertCompatibilitySteamLaunchPreference(
            compatibility,
            now: compatibilityTime
        )

        XCTAssertEqual(try preference.decodedSnapshot(), compatibility)
        XCTAssertEqual(standard.configurationDigest, standardDigest)
        XCTAssertEqual(standard.updatedAt, standardTime)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<StandardSteamLaunchConfigurationRecord>()).count,
            1
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<CompatibilitySteamLaunchPreferenceRecord>()).count,
            1
        )
    }

    func testRecordsRejectPayloadDigestAndIdentityCorruption() throws {
        let standard = try StandardSteamLaunchConfigurationRecord(
            snapshot: .standardDefault,
            now: Date(timeIntervalSince1970: 1)
        )
        let originalPayload = standard.canonicalConfigurationPayload
        standard.canonicalConfigurationPayload.append(0)
        XCTAssertThrowsError(try standard.decodedSnapshot())
        standard.canonicalConfigurationPayload = originalPayload
        standard.configurationDigest = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try standard.decodedSnapshot())

        let compatibilitySnapshot = try SteamLaunchConfigurationSnapshot.compatibilityDefault(
            steamAppID: "553850",
            profileID: "helldivers-2",
            recipeRevision: "v1"
        )
        let compatibility = try CompatibilitySteamLaunchPreferenceRecord(
            snapshot: compatibilitySnapshot,
            now: Date(timeIntervalSince1970: 1)
        )
        compatibility.profileID = "different-profile"
        XCTAssertThrowsError(try compatibility.decodedSnapshot())
    }

    func testConfigurationUpsertsRejectUnrelatedDirtyStateWithoutCommitOrRollback() throws {
        do {
            let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
            let context = container.mainContext
            let sentinel = AppSettingsRecord(
                id: "standard-upsert-dirty-sentinel",
                themeMode: "baseline"
            )
            context.insert(sentinel)
            try context.save()
            sentinel.themeMode = "pending-standard-change"

            XCTAssertThrowsError(
                try context.upsertStandardSteamLaunchConfiguration(.standardDefault)
            ) { error in
                XCTAssertEqual(
                    error as? SteamLaunchConfigurationPersistenceError,
                    .contextHasPendingChanges
                )
            }
            XCTAssertTrue(context.hasChanges)
            XCTAssertEqual(sentinel.themeMode, "pending-standard-change")

            let observer = ModelContext(container)
            let persistedSentinel = try XCTUnwrap(
                observer.fetch(FetchDescriptor<AppSettingsRecord>()).first
            )
            XCTAssertEqual(persistedSentinel.themeMode, "baseline")
            XCTAssertTrue(
                try observer.fetch(
                    FetchDescriptor<StandardSteamLaunchConfigurationRecord>()
                ).isEmpty
            )
        }

        do {
            let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
            let context = container.mainContext
            let sentinel = AppSettingsRecord(
                id: "compatibility-upsert-dirty-sentinel",
                themeMode: "baseline"
            )
            context.insert(sentinel)
            try context.save()
            sentinel.themeMode = "pending-compatibility-change"
            let compatibility = try SteamLaunchConfigurationSnapshot.compatibilityDefault(
                steamAppID: "553850",
                profileID: "helldivers-2",
                recipeRevision: "v1"
            )

            XCTAssertThrowsError(
                try context.upsertCompatibilitySteamLaunchPreference(compatibility)
            ) { error in
                XCTAssertEqual(
                    error as? SteamLaunchConfigurationPersistenceError,
                    .contextHasPendingChanges
                )
            }
            XCTAssertTrue(context.hasChanges)
            XCTAssertEqual(sentinel.themeMode, "pending-compatibility-change")

            let observer = ModelContext(container)
            let persistedSentinel = try XCTUnwrap(
                observer.fetch(FetchDescriptor<AppSettingsRecord>()).first
            )
            XCTAssertEqual(persistedSentinel.themeMode, "baseline")
            XCTAssertTrue(
                try observer.fetch(
                    FetchDescriptor<CompatibilitySteamLaunchPreferenceRecord>()
                ).isEmpty
            )
        }
    }

    func testRepositoryPreservesDirtyMainContextWhileSavingInDedicatedContexts() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let mainContext = container.mainContext
        let sentinel = AppSettingsRecord(
            id: "repository-dirty-main-context-sentinel",
            themeMode: "baseline"
        )
        mainContext.insert(sentinel)
        try mainContext.save()
        sentinel.themeMode = "pending-main-context-change"

        let repository = SteamLaunchConfigurationRepository(container: container)
        let standard = try repository.saveStandard(
            .standardDefault,
            expectedVersion: nil
        )
        let compatibilitySnapshot = try SteamLaunchConfigurationSnapshot.compatibilityDefault(
            steamAppID: "553850",
            profileID: "helldivers-2",
            recipeRevision: "v1"
        )
        let compatibilityIdentity = try XCTUnwrap(
            compatibilitySnapshot.identity.compatibilityProfile
        )
        let compatibility = try repository.saveCompatibility(
            compatibilitySnapshot,
            expectedVersion: nil
        )

        XCTAssertTrue(mainContext.hasChanges)
        XCTAssertEqual(sentinel.themeMode, "pending-main-context-change")
        XCTAssertEqual(try XCTUnwrap(repository.loadStandard()), standard)
        XCTAssertEqual(
            try XCTUnwrap(
                repository.loadCompatibility(identity: compatibilityIdentity)
            ),
            compatibility
        )

        let observer = ModelContext(container)
        let persistedSentinel = try XCTUnwrap(
            observer.fetch(FetchDescriptor<AppSettingsRecord>()).first
        )
        XCTAssertEqual(persistedSentinel.themeMode, "baseline")
    }

    func testRepositoryRejectsStaleWriterWithoutOverwritingNewerValue() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let firstWriter = SteamLaunchConfigurationRepository(container: container)
        let secondWriter = SteamLaunchConfigurationRepository(container: container)
        _ = try firstWriter.saveStandard(.standardDefault, expectedVersion: nil)
        let firstDraft = try XCTUnwrap(firstWriter.loadStandard())
        let staleDraft = try XCTUnwrap(secondWriter.loadStandard())
        let firstUpdate = try SteamLaunchConfigurationSnapshot(
            identity: .standard,
            graphicsBackend: .dxmt,
            gameModeEnabled: false
        )
        let staleUpdate = try SteamLaunchConfigurationSnapshot(
            identity: .standard,
            graphicsBackend: .d9vk,
            gameModeEnabled: true
        )

        let committed = try firstWriter.saveStandard(
            firstUpdate,
            expectedVersion: firstDraft.version
        )
        XCTAssertThrowsError(
            try secondWriter.saveStandard(
                staleUpdate,
                expectedVersion: staleDraft.version
            )
        ) { error in
            XCTAssertEqual(
                error as? SteamLaunchConfigurationPersistenceError,
                .writeConflict(type: "standard", id: "standard-default")
            )
        }

        XCTAssertEqual(try XCTUnwrap(firstWriter.loadStandard()), committed)
        XCTAssertEqual(committed.snapshot, firstUpdate)
        XCTAssertNotEqual(committed.version.revision, firstDraft.version.revision)
    }

    func testRepositoryReloadAfterConflictAllowsSavingLatestDraft() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let firstWriter = SteamLaunchConfigurationRepository(container: container)
        let secondWriter = SteamLaunchConfigurationRepository(container: container)
        _ = try firstWriter.saveStandard(.standardDefault, expectedVersion: nil)
        let firstDraft = try XCTUnwrap(firstWriter.loadStandard())
        let staleDraft = try XCTUnwrap(secondWriter.loadStandard())
        let firstUpdate = try SteamLaunchConfigurationSnapshot(
            identity: .standard,
            graphicsBackend: .dxmt,
            gameModeEnabled: false
        )
        _ = try firstWriter.saveStandard(
            firstUpdate,
            expectedVersion: firstDraft.version
        )
        let secondUpdate = try SteamLaunchConfigurationSnapshot(
            identity: .standard,
            graphicsBackend: .d9vk,
            gameModeEnabled: false
        )

        XCTAssertThrowsError(
            try secondWriter.saveStandard(
                secondUpdate,
                expectedVersion: staleDraft.version
            )
        )
        let reloaded = try XCTUnwrap(secondWriter.loadStandard())
        let committed = try secondWriter.saveStandard(
            secondUpdate,
            expectedVersion: reloaded.version
        )

        XCTAssertEqual(committed.snapshot, secondUpdate)
        XCTAssertNotEqual(committed.version.revision, reloaded.version.revision)
        XCTAssertEqual(try XCTUnwrap(firstWriter.loadStandard()), committed)
    }

    func testRepositoryKeepsStandardAndCompatibilityRecordsIndependent() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let repository = SteamLaunchConfigurationRepository(container: container)
        let originalStandard = try repository.saveStandard(
            .standardDefault,
            expectedVersion: nil
        )
        let compatibilitySnapshot = try SteamLaunchConfigurationSnapshot.compatibilityDefault(
            steamAppID: "553850",
            profileID: "helldivers-2",
            recipeRevision: "v1"
        )
        let identity = try XCTUnwrap(compatibilitySnapshot.identity.compatibilityProfile)
        let originalCompatibility = try repository.saveCompatibility(
            compatibilitySnapshot,
            expectedVersion: nil
        )
        let changedStandardSnapshot = try SteamLaunchConfigurationSnapshot(
            identity: .standard,
            graphicsBackend: .dxmt,
            gameModeEnabled: false
        )

        let changedStandard = try repository.saveStandard(
            changedStandardSnapshot,
            expectedVersion: originalStandard.version
        )
        XCTAssertEqual(
            try XCTUnwrap(repository.loadCompatibility(identity: identity)),
            originalCompatibility
        )
        try repository.resetStandard(expectedVersion: changedStandard.version)
        XCTAssertNil(try repository.loadStandard())
        XCTAssertEqual(
            try XCTUnwrap(repository.loadCompatibility(identity: identity)),
            originalCompatibility
        )

        let recreatedStandard = try repository.saveStandard(
            .standardDefault,
            expectedVersion: nil
        )
        try repository.resetCompatibility(
            identity: identity,
            expectedVersion: originalCompatibility.version
        )
        XCTAssertNil(try repository.loadCompatibility(identity: identity))
        XCTAssertEqual(try XCTUnwrap(repository.loadStandard()), recreatedStandard)
    }

    func testRepositoryDoesNotOverwriteCorruptExistingRecord() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let repository = SteamLaunchConfigurationRepository(container: container)
        let original = try repository.saveStandard(
            .standardDefault,
            expectedVersion: nil
        )
        let corruptionContext = ModelContext(container)
        corruptionContext.autosaveEnabled = false
        let record = try XCTUnwrap(
            corruptionContext.fetch(
                FetchDescriptor<StandardSteamLaunchConfigurationRecord>()
            ).first
        )
        record.canonicalConfigurationPayload.append(0)
        try corruptionContext.save()
        let corruptPayload = record.canonicalConfigurationPayload
        XCTAssertThrowsError(try repository.loadStandard())
        let recoveryVersion = try XCTUnwrap(
            repository.standardRecordVersionForRecovery()
        )
        XCTAssertEqual(recoveryVersion, original.version)
        let replacement = try SteamLaunchConfigurationSnapshot(
            identity: .standard,
            graphicsBackend: .dxmt
        )

        XCTAssertThrowsError(
            try repository.saveStandard(
                replacement,
                expectedVersion: original.version
            )
        )

        let observer = ModelContext(container)
        let persistedRecord = try XCTUnwrap(
            observer.fetch(FetchDescriptor<StandardSteamLaunchConfigurationRecord>()).first
        )
        XCTAssertEqual(persistedRecord.canonicalConfigurationPayload, corruptPayload)
        XCTAssertEqual(persistedRecord.persistenceRevision, original.version.revision)

        try repository.resetStandard(expectedVersion: recoveryVersion)
        XCTAssertNil(try repository.standardRecordVersionForRecovery())
        XCTAssertNil(try repository.loadStandard())
    }

    func testRepositoryRecoveryResetAcceptsExactCorruptDigestToken() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let repository = SteamLaunchConfigurationRepository(container: container)
        _ = try repository.saveStandard(.standardDefault, expectedVersion: nil)
        let corruptionContext = ModelContext(container)
        corruptionContext.autosaveEnabled = false
        let record = try XCTUnwrap(
            corruptionContext.fetch(
                FetchDescriptor<StandardSteamLaunchConfigurationRecord>()
            ).first
        )
        record.configurationDigest = "corrupt-digest"
        try corruptionContext.save()

        XCTAssertThrowsError(try repository.loadStandard())
        let recoveryVersion = try XCTUnwrap(
            repository.standardRecordVersionForRecovery()
        )
        XCTAssertEqual(recoveryVersion.digest, "corrupt-digest")
        XCTAssertEqual(recoveryVersion.revision, record.persistenceRevision)

        try repository.resetStandard(expectedVersion: recoveryVersion)
        XCTAssertNil(try repository.standardRecordVersionForRecovery())
        XCTAssertNil(try repository.loadStandard())
    }

    func testRepositoryRecoveryResetAcceptsExactZeroRevisionToken() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let repository = SteamLaunchConfigurationRepository(container: container)
        _ = try repository.saveStandard(.standardDefault, expectedVersion: nil)
        let corruptionContext = ModelContext(container)
        corruptionContext.autosaveEnabled = false
        let record = try XCTUnwrap(
            corruptionContext.fetch(
                FetchDescriptor<StandardSteamLaunchConfigurationRecord>()
            ).first
        )
        let zeroRevision = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000000")
        )
        record.persistenceRevision = zeroRevision
        try corruptionContext.save()

        XCTAssertThrowsError(try repository.loadStandard())
        let recoveryVersion = try XCTUnwrap(
            repository.standardRecordVersionForRecovery()
        )
        XCTAssertEqual(recoveryVersion.digest, record.configurationDigest)
        XCTAssertEqual(recoveryVersion.revision, zeroRevision)

        try repository.resetStandard(expectedVersion: recoveryVersion)
        XCTAssertNil(try repository.standardRecordVersionForRecovery())
        XCTAssertNil(try repository.loadStandard())
    }

    func testRepositoryRecoveryResetRejectsStaleToken() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let repository = SteamLaunchConfigurationRepository(container: container)
        let original = try repository.saveStandard(
            .standardDefault,
            expectedVersion: nil
        )
        let staleRecoveryVersion = try XCTUnwrap(
            repository.standardRecordVersionForRecovery()
        )
        let replacement = try SteamLaunchConfigurationSnapshot(
            identity: .standard,
            graphicsBackend: .dxmt,
            gameModeEnabled: false
        )
        let current = try repository.saveStandard(
            replacement,
            expectedVersion: original.version
        )

        XCTAssertThrowsError(
            try repository.resetStandard(expectedVersion: staleRecoveryVersion)
        ) { error in
            XCTAssertEqual(
                error as? SteamLaunchConfigurationPersistenceError,
                .writeConflict(type: "standard", id: "standard-default")
            )
        }
        XCTAssertEqual(try XCTUnwrap(repository.loadStandard()), current)
    }

    func testStandardRepositoryRejectsNoncanonicalSingletonIdentityEverywhere() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let corruptionContext = ModelContext(container)
        corruptionContext.autosaveEnabled = false
        let malformed = try StandardSteamLaunchConfigurationRecord(
            snapshot: .standardDefault,
            now: Date(timeIntervalSince1970: 1)
        )
        malformed.id = "unexpected-standard-row"
        corruptionContext.insert(malformed)
        try corruptionContext.save()

        let repository = SteamLaunchConfigurationRepository(container: container)
        let expectedError = SteamLaunchConfigurationPersistenceError
            .recordIdentityMismatch("standard-table-singleton-id")

        XCTAssertThrowsError(try repository.loadStandard()) { error in
            XCTAssertEqual(error as? SteamLaunchConfigurationPersistenceError, expectedError)
        }
        XCTAssertThrowsError(try repository.standardRecordVersionForRecovery()) { error in
            XCTAssertEqual(error as? SteamLaunchConfigurationPersistenceError, expectedError)
        }
        XCTAssertThrowsError(
            try repository.saveStandard(.standardDefault, expectedVersion: nil)
        ) { error in
            XCTAssertEqual(error as? SteamLaunchConfigurationPersistenceError, expectedError)
        }
        XCTAssertThrowsError(try repository.resetStandard(expectedVersion: nil)) { error in
            XCTAssertEqual(error as? SteamLaunchConfigurationPersistenceError, expectedError)
        }

        let observer = ModelContext(container)
        let persisted = try observer.fetch(
            FetchDescriptor<StandardSteamLaunchConfigurationRecord>()
        )
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.id, "unexpected-standard-row")
    }

    func testLaunchRecordProjectsResolvedAppliedAndRestoredJournal() throws {
        let snapshot = SteamLaunchConfigurationSnapshot.standardDefault
        let digest = try snapshot.canonicalDigest
        let baseline = String(repeating: "b", count: 64)
        var journal = try SteamLaunchConfigurationTransactionJournal(requestedDigest: digest)
        try journal.resolve(resolvedDigest: digest)
        let record = LaunchRecord(prefixId: "steam-shared", commandKind: "launchSteam")

        try record.bindResolvedLaunchConfiguration(snapshot: snapshot, journal: journal)
        XCTAssertEqual(record.launchModeRawValue, SteamLaunchMode.standard.rawValue)
        XCTAssertEqual(record.launchConfigurationIdentity, "standard-default")
        XCTAssertEqual(record.launchConfigurationSchemaVersion, 1)
        XCTAssertEqual(record.launchConfigurationPayload, try snapshot.canonicalPayload())
        XCTAssertEqual(record.launchConfigurationDigest, digest)
        XCTAssertEqual(record.launchConfigurationTransactionState, "resolved")
        XCTAssertEqual(record.launchConfigurationRestorationState, "notRequired")

        try journal.apply(appliedDigest: digest, capturedBaselineDigest: baseline)
        try record.bindResolvedLaunchConfiguration(snapshot: snapshot, journal: journal)
        XCTAssertEqual(record.launchConfigurationTransactionState, "applied")
        XCTAssertEqual(record.launchConfigurationRestorationState, "pending")

        try journal.markRestored(restoredBaselineDigest: baseline)
        try record.bindResolvedLaunchConfiguration(snapshot: snapshot, journal: journal)
        XCTAssertEqual(record.launchConfigurationTransactionState, "restored")
        XCTAssertEqual(record.launchConfigurationRestorationState, "succeeded")

        try record.bindResolvedLaunchConfiguration(snapshot: nil, journal: nil)
        assertProjectionIsNil(record)
    }

    func testLaunchRecordRejectsRequestedAndMismatchedJournalWithoutMutation() throws {
        let snapshot = SteamLaunchConfigurationSnapshot.standardDefault
        let digest = try snapshot.canonicalDigest
        var resolved = try SteamLaunchConfigurationTransactionJournal(requestedDigest: digest)
        try resolved.resolve(resolvedDigest: digest)
        let record = LaunchRecord(prefixId: "steam-shared", commandKind: "launchSteam")
        try record.bindResolvedLaunchConfiguration(snapshot: snapshot, journal: resolved)
        let originalDigest = record.launchConfigurationDigest
        let originalTransactionID = record.launchConfigurationTransactionID
        let originalState = record.launchConfigurationTransactionState

        let requested = try SteamLaunchConfigurationTransactionJournal(requestedDigest: digest)
        XCTAssertThrowsError(
            try record.bindResolvedLaunchConfiguration(snapshot: snapshot, journal: requested)
        )
        XCTAssertEqual(record.launchConfigurationDigest, originalDigest)
        XCTAssertEqual(record.launchConfigurationTransactionID, originalTransactionID)
        XCTAssertEqual(record.launchConfigurationTransactionState, originalState)

        let otherDigest = String(repeating: "c", count: 64)
        var mismatched = try SteamLaunchConfigurationTransactionJournal(
            requestedDigest: otherDigest
        )
        try mismatched.resolve(resolvedDigest: otherDigest)
        XCTAssertThrowsError(
            try record.bindResolvedLaunchConfiguration(snapshot: snapshot, journal: mismatched)
        )
        XCTAssertEqual(record.launchConfigurationDigest, originalDigest)
        XCTAssertEqual(record.launchConfigurationTransactionID, originalTransactionID)
        XCTAssertEqual(record.launchConfigurationTransactionState, originalState)

        XCTAssertThrowsError(
            try record.bindResolvedLaunchConfiguration(snapshot: snapshot, journal: nil)
        )
        XCTAssertThrowsError(
            try record.bindResolvedLaunchConfiguration(snapshot: nil, journal: resolved)
        )
    }

    func testForgePlayModelContainerIncludesBothConfigurationModels() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        _ = try context.upsertStandardSteamLaunchConfiguration(.standardDefault)
        let compatibility = try SteamLaunchConfigurationSnapshot.compatibilityDefault(
            steamAppID: "553850",
            profileID: "helldivers-2",
            recipeRevision: "v1"
        )
        _ = try context.upsertCompatibilitySteamLaunchPreference(compatibility)

        XCTAssertEqual(
            try context.fetch(FetchDescriptor<StandardSteamLaunchConfigurationRecord>()).count,
            1
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<CompatibilitySteamLaunchPreferenceRecord>()).count,
            1
        )
    }

    func testCreateSteamLaunchRecordWithoutConfigurationKeepsProjectionNil() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext

        _ = try context.createSteamLaunchRecord(appSessionID: "session-without-configuration")
        let records = try context.fetch(FetchDescriptor<LaunchRecord>())

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        assertProjectionIsNil(record)
    }

    func testCreateSteamLaunchRecordBindsResolvedConfigurationBeforeSaving() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let snapshot = SteamLaunchConfigurationSnapshot.standardDefault
        let transactionID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let journal = try SteamLaunchConfigurationProductAdapter.resolvedJournal(
            for: snapshot,
            transactionID: transactionID
        )

        let created = try context.createSteamLaunchRecord(
            appSessionID: "session-with-configuration",
            resolvedSnapshot: snapshot,
            resolvedJournal: journal
        )
        let records = try context.fetch(FetchDescriptor<LaunchRecord>())

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertTrue(record === created)
        XCTAssertEqual(record.launchModeRawValue, SteamLaunchMode.standard.rawValue)
        XCTAssertEqual(record.launchConfigurationIdentity, "standard-default")
        XCTAssertEqual(record.launchConfigurationSchemaVersion, snapshot.schemaVersion)
        XCTAssertEqual(record.launchConfigurationPayload, try snapshot.canonicalPayload())
        XCTAssertEqual(record.launchConfigurationDigest, try snapshot.canonicalDigest)
        XCTAssertEqual(
            record.launchConfigurationTransactionID,
            transactionID.uuidString.lowercased()
        )
        XCTAssertEqual(record.launchConfigurationTransactionState, "resolved")
        XCTAssertEqual(record.launchConfigurationRestorationState, "notRequired")
    }

    func testCreateSteamLaunchRecordRejectsRequestedOrMismatchedJournalWithoutInsert() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let snapshot = SteamLaunchConfigurationSnapshot.standardDefault
        let digest = try snapshot.canonicalDigest
        let requested = try SteamLaunchConfigurationTransactionJournal(
            requestedDigest: digest
        )

        XCTAssertThrowsError(
            try context.createSteamLaunchRecord(
                appSessionID: "requested-journal",
                resolvedSnapshot: snapshot,
                resolvedJournal: requested
            )
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<LaunchRecord>()).count, 0)

        let otherDigest = String(repeating: "c", count: 64)
        var mismatched = try SteamLaunchConfigurationTransactionJournal(
            requestedDigest: otherDigest
        )
        try mismatched.resolve(resolvedDigest: otherDigest)

        XCTAssertThrowsError(
            try context.createSteamLaunchRecord(
                appSessionID: "mismatched-journal",
                resolvedSnapshot: snapshot,
                resolvedJournal: mismatched
            )
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<LaunchRecord>()).count, 0)
    }

    private func assertProjectionIsNil(
        _ record: LaunchRecord,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(record.launchModeRawValue, file: file, line: line)
        XCTAssertNil(record.launchConfigurationIdentity, file: file, line: line)
        XCTAssertNil(record.launchConfigurationSchemaVersion, file: file, line: line)
        XCTAssertNil(record.launchConfigurationPayload, file: file, line: line)
        XCTAssertNil(record.launchConfigurationDigest, file: file, line: line)
        XCTAssertNil(record.launchConfigurationTransactionID, file: file, line: line)
        XCTAssertNil(record.launchConfigurationTransactionState, file: file, line: line)
        XCTAssertNil(record.launchConfigurationRestorationState, file: file, line: line)
    }
}
