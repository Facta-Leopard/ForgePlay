import Foundation
import SwiftData

enum SteamPrefixState: String, Hashable {
    case rootNotConfigured
    case rootUnavailable
    case prefixMissing
    case prefixInvalid
    case steamMissing
    case runtimeMigrationRequired
    case rendererUnverified
    case rendererNeedsApply
    case rendererNeedsRepair
    case runtimeUnavailable
    case launchReady

    var allowsSteamLaunch: Bool {
        self == .launchReady || self == .rendererNeedsApply
    }
}

struct SetupReadiness: Hashable {
    var hasSteamPrefix: Bool
    var hasSteamExecutable: Bool
    var hasSteamReferences: Bool
    var steamPrefixURL: URL?
    var steamExecutableURL: URL?
    var rootIssue: PathManagerError?
    var steamPrefixIssue: PrefixUsabilityError?
    var runtimeCompatibilityInspection: PrefixRuntimeCompatibilityInspection?
    var rendererInspection: SteamRendererPolicyInspection?
    var steamUIVerificationState: SteamUIVerificationState
    var steamUISurface: SteamUISurface?
    var steamSessionInspection: SteamSessionInspection
    var steamSessionContinuityState: SteamSessionContinuityState
    var steamEnvironmentCreatedAt: Date?
    var steamEnvironmentGenerationID: String?

    init(
        hasSteamPrefix: Bool,
        hasSteamExecutable: Bool,
        hasSteamReferences: Bool,
        steamPrefixURL: URL?,
        steamExecutableURL: URL?,
        rootIssue: PathManagerError? = nil,
        steamPrefixIssue: PrefixUsabilityError? = nil,
        runtimeCompatibilityInspection: PrefixRuntimeCompatibilityInspection? = nil,
        rendererInspection: SteamRendererPolicyInspection? = nil,
        steamUIVerificationState: SteamUIVerificationState = .notRun,
        steamUISurface: SteamUISurface? = nil,
        steamSessionInspection: SteamSessionInspection = .unavailable,
        steamSessionContinuityState: SteamSessionContinuityState = .notVerified,
        steamEnvironmentCreatedAt: Date? = nil,
        steamEnvironmentGenerationID: String? = nil
    ) {
        self.hasSteamPrefix = hasSteamPrefix
        self.hasSteamExecutable = hasSteamExecutable
        self.hasSteamReferences = hasSteamReferences
        self.steamPrefixURL = steamPrefixURL
        self.steamExecutableURL = steamExecutableURL
        self.rootIssue = rootIssue
        self.steamPrefixIssue = steamPrefixIssue
        self.runtimeCompatibilityInspection = runtimeCompatibilityInspection
        self.rendererInspection = rendererInspection
        self.steamUIVerificationState = steamUIVerificationState
        self.steamUISurface = steamUISurface
        self.steamSessionInspection = steamSessionInspection
        self.steamSessionContinuityState = steamSessionContinuityState
        self.steamEnvironmentCreatedAt = steamEnvironmentCreatedAt
        self.steamEnvironmentGenerationID = steamEnvironmentGenerationID
    }

    static let empty = SetupReadiness(
        hasSteamPrefix: false,
        hasSteamExecutable: false,
        hasSteamReferences: false,
        steamPrefixURL: nil,
        steamExecutableURL: nil
    )

    var steamPrefixState: SteamPrefixState {
        if rootIssue != nil {
            return .rootUnavailable
        }
        guard steamPrefixURL != nil else {
            return .rootNotConfigured
        }
        if steamPrefixIssue != nil {
            return .prefixInvalid
        }
        guard hasSteamPrefix else {
            return .prefixMissing
        }
        guard hasSteamExecutable else {
            return .steamMissing
        }
        switch runtimeCompatibilityInspection {
        case .migrationRequired:
            return .runtimeMigrationRequired
        case .runtimeUnavailable:
            return .runtimeUnavailable
        case .compatible, .none:
            break
        }
        guard let rendererInspection else {
            return .rendererUnverified
        }
        if rendererInspection.effectiveRecoveryKind == .runtimeUnavailable {
            return .runtimeUnavailable
        }
        if rendererInspection.requiresRepair {
            return .rendererNeedsRepair
        }
        if rendererInspection.requiresApply || rendererInspection.status != .ok {
            return .rendererNeedsApply
        }
        return .launchReady
    }

    var canAttemptWindowsSteamLaunch: Bool {
        guard rootIssue == nil,
              steamPrefixURL != nil,
              hasSteamPrefix,
              hasSteamExecutable else {
            return false
        }
        if let steamPrefixIssue {
            switch steamPrefixIssue {
            case .invalidMetadata, .architectureMismatch:
                // Metadata and migration diagnostics describe repair work, not
                // whether the existing Wine prefix and steam.exe can be
                // attempted. The launch path records the warning and lets the
                // runtime report the real execution result.
                break
            case .missingRequiredItem,
                 .unsafeRequiredItem,
                 .unreadableRequiredItem:
                return false
            }
        }
        // Runtime/renderer inspections are advisory. A stale or incomplete
        // readback must not prevent a user from attempting Windows Steam when
        // the concrete runtime, prefix and steam.exe launch inputs exist.
        return true
    }

    var hasDetectedSteamAccountSession: Bool {
        switch steamSessionInspection.state {
        case .accountDataPresent, .rememberedSignInConfigured:
            true
        case .unavailable, .noAccountData, .invalid:
            false
        }
    }

    var hasVerifiedWindowsSteamUI: Bool {
        steamUIVerificationState == .rendered
    }

    var hasVerifiedAuthenticatedLibrary: Bool {
        steamUIVerificationState == .rendered && steamUISurface == .library
    }

    var hasVerifiedSessionPersistence: Bool {
        steamSessionContinuityState == .libraryVerifiedAfterRelaunch
    }

    var currentSteamSurfaceRequiresAuthentication: Bool {
        steamUISurface == .signIn || steamUISurface == .steamGuard
    }

    var hasUsableAuthenticatedSteamSession: Bool {
        guard !currentSteamSurfaceRequiresAuthentication else { return false }
        return hasVerifiedAuthenticatedLibrary || hasVerifiedSessionPersistence
    }

    var hasAppliedRendererPolicyForSteam: Bool {
        guard let rendererInspection else { return false }
        return rendererInspection.status == .ok && !rendererInspection.requiresApply && !rendererInspection.requiresRepair
    }

    func withSteamUIVerification(_ state: SteamUIVerificationState) -> SetupReadiness {
        SetupReadiness(
            hasSteamPrefix: hasSteamPrefix,
            hasSteamExecutable: hasSteamExecutable,
            hasSteamReferences: hasSteamReferences,
            steamPrefixURL: steamPrefixURL,
            steamExecutableURL: steamExecutableURL,
            rootIssue: rootIssue,
            steamPrefixIssue: steamPrefixIssue,
            runtimeCompatibilityInspection: runtimeCompatibilityInspection,
            rendererInspection: rendererInspection,
            steamUIVerificationState: state,
            steamUISurface: steamUISurface,
            steamSessionInspection: steamSessionInspection,
            steamSessionContinuityState: steamSessionContinuityState,
            steamEnvironmentCreatedAt: steamEnvironmentCreatedAt,
            steamEnvironmentGenerationID: steamEnvironmentGenerationID
        )
    }

    func withSteamLaunchReadinessProjection(
        _ projection: SteamLaunchReadinessProjection
    ) -> SetupReadiness {
        let identity = SteamEnvironmentIdentity(
            generationID: steamEnvironmentGenerationID,
            createdAt: steamEnvironmentCreatedAt
        )
        guard projection.environmentIdentity == identity else {
            var updated = withSteamUIVerification(.notRun)
            updated.steamUISurface = nil
            updated.steamSessionContinuityState = .notVerified
            return updated
        }

        let latest = projection.latestCurrentSessionRecord
        let latestState = latest?.verificationStatus
            .flatMap(SteamUIVerificationState.init(rawValue:)) ?? .notRun
        var updated = withSteamUIVerification(latestState)
        updated.steamUISurface = latest?.surface
            .flatMap(SteamUISurface.init(rawValue:))
        if projection.libraryVerificationRecords.count >= 2 {
            updated.steamSessionContinuityState = .libraryVerifiedAfterRelaunch
        } else if !projection.libraryVerificationRecords.isEmpty {
            updated.steamSessionContinuityState = .libraryVerifiedOnce
        } else {
            updated.steamSessionContinuityState = .notVerified
        }
        return updated
    }

    func steamPrefixTargetURL(selectedRootURL: URL?) -> URL? {
        guard rootIssue == nil else { return nil }
        if let steamPrefixURL { return steamPrefixURL }
        return selectedRootURL?.appending(
            path: ForgePlayPathRole.steamSharedPrefix.rawValue,
            directoryHint: .isDirectory
        )
    }
}

struct SteamEnvironmentIdentity: Equatable, Sendable {
    let generationID: String?
    let createdAt: Date?

    var isEstablished: Bool {
        generationID != nil || createdAt != nil
    }
}

struct SteamLaunchReadinessProjection: Equatable, Sendable {
    let environmentIdentity: SteamEnvironmentIdentity
    let latestCurrentSessionRecord:
        SteamLaunchRecordLookup.ReadinessFingerprint.Record?
    let libraryVerificationRecords:
        [SteamLaunchRecordLookup.ReadinessFingerprint.Record]

    var fingerprint: SteamLaunchRecordLookup.ReadinessFingerprint {
        var records: [SteamLaunchRecordLookup.ReadinessFingerprint.Record] = []
        var seenRecordIDs = Set<String>()
        if let latestCurrentSessionRecord,
           seenRecordIDs.insert(latestCurrentSessionRecord.id).inserted {
            records.append(latestCurrentSessionRecord)
        }
        for record in libraryVerificationRecords
        where seenRecordIDs.insert(record.id).inserted {
            records.append(record)
        }
        return SteamLaunchRecordLookup.ReadinessFingerprint(
            environmentGenerationID: environmentIdentity.generationID,
            environmentCreatedAt: environmentIdentity.createdAt,
            records: records
        )
    }

    static func empty(
        environmentIdentity: SteamEnvironmentIdentity = .init(
            generationID: nil,
            createdAt: nil
        )
    ) -> Self {
        Self(
            environmentIdentity: environmentIdentity,
            latestCurrentSessionRecord: nil,
            libraryVerificationRecords: []
        )
    }
}

enum SteamLaunchRecordLookup {
    struct ReadinessFingerprint: Equatable, Sendable {
        struct Record: Equatable, Sendable {
            let id: String
            let startedAt: Date
            let verificationStatus: String?
            let surface: String?
            let hostAppSessionID: String?
            let environmentGenerationID: String?
            let exitCode: Int32?
        }

        let environmentGenerationID: String?
        let environmentCreatedAt: Date?
        let records: [Record]

        init(
            environmentGenerationID: String? = nil,
            environmentCreatedAt: Date? = nil,
            records: [Record]
        ) {
            self.environmentGenerationID = environmentGenerationID
            self.environmentCreatedAt = environmentCreatedAt
            self.records = records
        }
    }

    static func stateFingerprint(from records: [LaunchRecord]) -> String {
        fingerprint(
            records
            .filter { $0.commandKind == "launchSteam" && $0.prefixId == PrefixIdentifier.steamShared }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(32)
        )
    }

    /// Computes the same bounded fingerprint without sorting when the caller
    /// already owns a newest-first query result.
    static func newestFirstStateFingerprint(from records: [LaunchRecord]) -> String {
        fingerprint(
            records.lazy
                .filter {
                    $0.commandKind == "launchSteam" &&
                        $0.prefixId == PrefixIdentifier.steamShared
                }
                .prefix(32)
        )
    }

    /// Semantic readiness projection for a caller-owned newest-first query.
    /// It retains only the latest record for the active app session and the
    /// first two distinct library-verification sessions required by the
    /// continuity contract.
    static func newestFirstReadinessFingerprint(
        from records: [LaunchRecord],
        environmentIdentity: SteamEnvironmentIdentity,
        currentAppSessionID: String? = nil
    ) -> ReadinessFingerprint {
        newestFirstReadinessProjection(
            from: records,
            environmentIdentity: environmentIdentity,
            currentAppSessionID: currentAppSessionID
        ).fingerprint
    }

    static func newestFirstReadinessProjection(
        from records: [LaunchRecord],
        environmentIdentity: SteamEnvironmentIdentity,
        currentAppSessionID: String?
    ) -> SteamLaunchReadinessProjection {
        var latestCurrentSessionRecord: ReadinessFingerprint.Record?
        var libraryVerificationRecords: [ReadinessFingerprint.Record] = []
        var libraryVerificationSessionIDs = Set<String>()

        for record in records {
            guard isRecord(record, in: environmentIdentity) else { continue }
            let projected = readinessRecord(record)
            if latestCurrentSessionRecord == nil,
               (currentAppSessionID == nil ||
                record.hostAppSessionID == currentAppSessionID) {
                latestCurrentSessionRecord = projected
            }
            if libraryVerificationRecords.count < 2,
               record.steamUIVerificationState == .rendered,
               record.steamUISurface == .library,
               let appSessionID = record.hostAppSessionID,
               !appSessionID.isEmpty,
               libraryVerificationSessionIDs.insert(appSessionID).inserted {
                libraryVerificationRecords.append(projected)
            }
            if latestCurrentSessionRecord != nil,
               libraryVerificationRecords.count == 2 {
                break
            }
        }
        return SteamLaunchReadinessProjection(
            environmentIdentity: environmentIdentity,
            latestCurrentSessionRecord: latestCurrentSessionRecord,
            libraryVerificationRecords: libraryVerificationRecords
        )
    }

    private static func isRecord(
        _ record: LaunchRecord,
        in environmentIdentity: SteamEnvironmentIdentity
    ) -> Bool {
        guard record.commandKind == "launchSteam",
              record.prefixId == PrefixIdentifier.steamShared,
              environmentIdentity.isEstablished else {
            return false
        }
        if let generationID = environmentIdentity.generationID {
            return record.environmentGenerationID == generationID
        }
        guard let createdAt = environmentIdentity.createdAt else { return false }
        return record.startedAt >= createdAt
    }

    fileprivate static func readinessRecord(
        _ record: LaunchRecord
    ) -> ReadinessFingerprint.Record {
        ReadinessFingerprint.Record(
            id: record.id,
            startedAt: record.startedAt,
            verificationStatus: record.steamUIVerificationStatus,
            surface: record.steamUISurfaceRawValue,
            hostAppSessionID: record.hostAppSessionID,
            environmentGenerationID: record.environmentGenerationID,
            exitCode: record.exitCode
        )
    }

    static func currentEnvironmentRecords(
        from records: [LaunchRecord],
        environmentGenerationID: String? = nil,
        environmentCreatedAt: Date?
    ) -> [LaunchRecord] {
        records.filter {
            $0.commandKind == "launchSteam" && $0.prefixId == PrefixIdentifier.steamShared
        }.filter { record in
            if let environmentGenerationID {
                return record.environmentGenerationID == environmentGenerationID
            }
            guard let environmentCreatedAt else { return true }
            return record.startedAt >= environmentCreatedAt
        }.sorted { $0.startedAt > $1.startedAt }
    }

    static func latestSteamLaunchRecord(
        from records: [LaunchRecord],
        environmentGenerationID: String? = nil,
        environmentCreatedAt: Date? = nil,
        currentAppSessionID: String? = nil
    ) -> LaunchRecord? {
        let records = currentEnvironmentRecords(
            from: records,
            environmentGenerationID: environmentGenerationID,
            environmentCreatedAt: environmentCreatedAt
        )
        return currentAppSessionID.map { appSessionID in
            records.first { $0.hostAppSessionID == appSessionID }
        } ?? records.first
    }

    /// Finds the same record as `latestSteamLaunchRecord` without allocating
    /// and sorting when `records` is already ordered newest first.
    static func latestSteamLaunchRecordFromNewestFirst(
        _ records: [LaunchRecord],
        environmentGenerationID: String? = nil,
        environmentCreatedAt: Date? = nil,
        currentAppSessionID: String? = nil
    ) -> LaunchRecord? {
        var newestEligibleRecord: LaunchRecord?
        for record in records {
            guard record.commandKind == "launchSteam",
                  record.prefixId == PrefixIdentifier.steamShared else {
                continue
            }
            if let environmentGenerationID {
                guard record.environmentGenerationID == environmentGenerationID else {
                    continue
                }
            } else if let environmentCreatedAt, record.startedAt < environmentCreatedAt {
                continue
            }
            if newestEligibleRecord == nil {
                newestEligibleRecord = record
            }
            guard let currentAppSessionID else { return record }
            if record.hostAppSessionID == currentAppSessionID {
                return record
            }
        }
        return newestEligibleRecord
    }

    static func latestSteamUIVerificationState(from records: [LaunchRecord]) -> SteamUIVerificationState {
        latestSteamLaunchRecord(from: records)?.steamUIVerificationState ?? .notRun
    }

    private static func fingerprint<S: Sequence>(_ records: S) -> String
    where S.Element == LaunchRecord {
        records.map {
            [
                $0.id,
                $0.steamUIVerificationStatus ?? "",
                $0.steamUISurfaceRawValue ?? "",
                $0.hostAppSessionID ?? "",
                $0.environmentGenerationID ?? "",
                $0.exitCode.map(String.init) ?? ""
            ].joined(separator: "|")
        }
        .joined(separator: "\n")
    }
}

struct SteamLaunchReadinessRepository {
    static let requiredContinuitySessionCount = 2
    static let retainedRecentOperationalRecordCount = 500
    static let retentionScanBatchSize = 128
    static let diagnosticLinkScanBatchSize = 256

    func readinessProjection(
        in context: ModelContext,
        environmentIdentity: SteamEnvironmentIdentity,
        currentAppSessionID: String
    ) throws -> SteamLaunchReadinessProjection {
        guard environmentIdentity.isEstablished else {
            return .empty(environmentIdentity: environmentIdentity)
        }
        return SteamLaunchReadinessProjection(
            environmentIdentity: environmentIdentity,
            latestCurrentSessionRecord: try latestRecord(
                in: context,
                environmentIdentity: environmentIdentity,
                appSessionID: currentAppSessionID
            ).map(SteamLaunchRecordLookup.readinessRecord),
            libraryVerificationRecords: try libraryVerificationRecords(
                in: context,
                environmentIdentity: environmentIdentity
            ).map(SteamLaunchRecordLookup.readinessRecord)
        )
    }

    /// Returns the one launch row presented by summary UI. Current-session
    /// evidence wins; otherwise the newest row in the active Steam environment
    /// is returned. Both branches are exact database queries with a one-row
    /// result bound.
    func latestDisplayRecord(
        in context: ModelContext,
        environmentIdentity: SteamEnvironmentIdentity,
        currentAppSessionID: String
    ) throws -> LaunchRecord? {
        guard environmentIdentity.isEstablished else { return nil }
        if let current = try latestRecord(
            in: context,
            environmentIdentity: environmentIdentity,
            appSessionID: currentAppSessionID
        ) {
            return current
        }
        return try latestRecord(
            in: context,
            environmentIdentity: environmentIdentity,
            appSessionID: nil
        )
    }

    /// Removes only completed Steam launch history that is outside the bounded
    /// operational window and is not required by readiness or diagnostics.
    /// Active/unfinished rows are excluded by the candidate predicate.
    @discardableResult
    func pruneCompletedHistory(
        in context: ModelContext,
        environmentIdentity: SteamEnvironmentIdentity,
        currentAppSessionID: String
    ) throws -> Int {
        let steamPrefixID = PrefixIdentifier.steamShared
        let steamCommand = "launchSteam"
        var recentDescriptor = FetchDescriptor<LaunchRecord>(
            predicate: #Predicate {
                $0.commandKind == steamCommand &&
                    $0.prefixId == steamPrefixID
            },
            sortBy: [
                SortDescriptor(\LaunchRecord.startedAt, order: .reverse),
                SortDescriptor(\LaunchRecord.id, order: .reverse)
            ]
        )
        recentDescriptor.fetchLimit = Self.retainedRecentOperationalRecordCount + 1
        let recentRecords = try context.fetch(recentDescriptor)
        guard recentRecords.count > Self.retainedRecentOperationalRecordCount else {
            return 0
        }
        var protectedRecordIDs = Set(
            recentRecords.prefix(Self.retainedRecentOperationalRecordCount).map(\.id)
        )

        let readiness = try readinessProjection(
            in: context,
            environmentIdentity: environmentIdentity,
            currentAppSessionID: currentAppSessionID
        )
        protectedRecordIDs.formUnion(readiness.fingerprint.records.map(\.id))
        protectedRecordIDs.formUnion(try diagnosticLinkedLaunchRecordIDs(in: context))

        let notRunStatus = SteamUIVerificationState.notRun.rawValue
        var retainedCandidateOffset = 0
        var deletedCount = 0
        while true {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<LaunchRecord>(
                predicate: #Predicate {
                    $0.commandKind == steamCommand &&
                        $0.prefixId == steamPrefixID &&
                        ($0.hostAppSessionID == nil ||
                            $0.hostAppSessionID != currentAppSessionID) &&
                        $0.endedAt != nil &&
                        $0.status != "running" &&
                        $0.steamUIVerificationStatus != notRunStatus
                },
                sortBy: [
                    SortDescriptor(\LaunchRecord.startedAt),
                    SortDescriptor(\LaunchRecord.id)
                ]
            )
            descriptor.fetchLimit = Self.retentionScanBatchSize
            descriptor.fetchOffset = retainedCandidateOffset
            let batch = try context.fetch(descriptor)
            guard !batch.isEmpty else { break }

            var protectedCount = 0
            var batchDeletionCount = 0
            for record in batch {
                if protectedRecordIDs.contains(record.id) {
                    protectedCount += 1
                } else {
                    context.delete(record)
                    batchDeletionCount += 1
                }
            }
            if batchDeletionCount > 0 {
                try context.saveOrRollback()
                deletedCount += batchDeletionCount
                // Deleted rows no longer occupy an offset. Only rows retained
                // from this page must be skipped on the next fetch.
                retainedCandidateOffset += protectedCount
            } else {
                retainedCandidateOffset += batch.count
            }
            if batch.count < Self.retentionScanBatchSize { break }
        }
        return deletedCount
    }

    private func latestRecord(
        in context: ModelContext,
        environmentIdentity: SteamEnvironmentIdentity,
        appSessionID: String?
    ) throws -> LaunchRecord? {
        let steamPrefixID = PrefixIdentifier.steamShared
        let steamCommand = "launchSteam"
        var descriptor: FetchDescriptor<LaunchRecord>
        if let generationID = environmentIdentity.generationID {
            if let appSessionID {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.commandKind == steamCommand &&
                            $0.prefixId == steamPrefixID &&
                            $0.environmentGenerationID == generationID &&
                            $0.hostAppSessionID == appSessionID
                    },
                    sortBy: [
                        SortDescriptor(\LaunchRecord.startedAt, order: .reverse),
                        SortDescriptor(\LaunchRecord.id, order: .reverse)
                    ]
                )
            } else {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.commandKind == steamCommand &&
                            $0.prefixId == steamPrefixID &&
                            $0.environmentGenerationID == generationID
                    },
                    sortBy: [
                        SortDescriptor(\LaunchRecord.startedAt, order: .reverse),
                        SortDescriptor(\LaunchRecord.id, order: .reverse)
                    ]
                )
            }
        } else if let createdAt = environmentIdentity.createdAt {
            if let appSessionID {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.commandKind == steamCommand &&
                            $0.prefixId == steamPrefixID &&
                            $0.startedAt >= createdAt &&
                            $0.hostAppSessionID == appSessionID
                    },
                    sortBy: [
                        SortDescriptor(\LaunchRecord.startedAt, order: .reverse),
                        SortDescriptor(\LaunchRecord.id, order: .reverse)
                    ]
                )
            } else {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.commandKind == steamCommand &&
                            $0.prefixId == steamPrefixID &&
                            $0.startedAt >= createdAt
                    },
                    sortBy: [
                        SortDescriptor(\LaunchRecord.startedAt, order: .reverse),
                        SortDescriptor(\LaunchRecord.id, order: .reverse)
                    ]
                )
            }
        } else {
            return nil
        }
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func libraryVerificationRecords(
        in context: ModelContext,
        environmentIdentity: SteamEnvironmentIdentity
    ) throws -> [LaunchRecord] {
        guard let first = try latestLibraryVerificationRecord(
            in: context,
            environmentIdentity: environmentIdentity,
            excludingAppSessionID: nil
        ),
        let firstSessionID = first.hostAppSessionID,
        !firstSessionID.isEmpty else {
            return []
        }
        guard let second = try latestLibraryVerificationRecord(
            in: context,
            environmentIdentity: environmentIdentity,
            excludingAppSessionID: firstSessionID
        ) else {
            return [first]
        }
        return [first, second]
    }

    private func latestLibraryVerificationRecord(
        in context: ModelContext,
        environmentIdentity: SteamEnvironmentIdentity,
        excludingAppSessionID: String?
    ) throws -> LaunchRecord? {
        let steamPrefixID = PrefixIdentifier.steamShared
        let steamCommand = "launchSteam"
        let renderedStatus = SteamUIVerificationState.rendered.rawValue
        let librarySurface = SteamUISurface.library.rawValue
        let emptySessionID = ""
        var descriptor: FetchDescriptor<LaunchRecord>
        if let generationID = environmentIdentity.generationID {
            if let excludingAppSessionID {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.commandKind == steamCommand &&
                            $0.prefixId == steamPrefixID &&
                            $0.environmentGenerationID == generationID &&
                            $0.steamUIVerificationStatus == renderedStatus &&
                            $0.steamUISurfaceRawValue == librarySurface &&
                            $0.hostAppSessionID != nil &&
                            $0.hostAppSessionID != emptySessionID &&
                            $0.hostAppSessionID != excludingAppSessionID
                    },
                    sortBy: [
                        SortDescriptor(\LaunchRecord.startedAt, order: .reverse),
                        SortDescriptor(\LaunchRecord.id, order: .reverse)
                    ]
                )
            } else {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.commandKind == steamCommand &&
                            $0.prefixId == steamPrefixID &&
                            $0.environmentGenerationID == generationID &&
                            $0.steamUIVerificationStatus == renderedStatus &&
                            $0.steamUISurfaceRawValue == librarySurface &&
                            $0.hostAppSessionID != nil &&
                            $0.hostAppSessionID != emptySessionID
                    },
                    sortBy: [
                        SortDescriptor(\LaunchRecord.startedAt, order: .reverse),
                        SortDescriptor(\LaunchRecord.id, order: .reverse)
                    ]
                )
            }
        } else if let createdAt = environmentIdentity.createdAt {
            if let excludingAppSessionID {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.commandKind == steamCommand &&
                            $0.prefixId == steamPrefixID &&
                            $0.startedAt >= createdAt &&
                            $0.steamUIVerificationStatus == renderedStatus &&
                            $0.steamUISurfaceRawValue == librarySurface &&
                            $0.hostAppSessionID != nil &&
                            $0.hostAppSessionID != emptySessionID &&
                            $0.hostAppSessionID != excludingAppSessionID
                    },
                    sortBy: [
                        SortDescriptor(\LaunchRecord.startedAt, order: .reverse),
                        SortDescriptor(\LaunchRecord.id, order: .reverse)
                    ]
                )
            } else {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.commandKind == steamCommand &&
                            $0.prefixId == steamPrefixID &&
                            $0.startedAt >= createdAt &&
                            $0.steamUIVerificationStatus == renderedStatus &&
                            $0.steamUISurfaceRawValue == librarySurface &&
                            $0.hostAppSessionID != nil &&
                            $0.hostAppSessionID != emptySessionID
                    },
                    sortBy: [
                        SortDescriptor(\LaunchRecord.startedAt, order: .reverse),
                        SortDescriptor(\LaunchRecord.id, order: .reverse)
                    ]
                )
            }
        } else {
            return nil
        }
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func diagnosticLinkedLaunchRecordIDs(
        in context: ModelContext
    ) throws -> Set<String> {
        var offset = 0
        var recordIDs = Set<String>()
        while true {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<DiagnosticRecord>(
                predicate: #Predicate { $0.launchRecordId != nil },
                sortBy: [
                    SortDescriptor(\DiagnosticRecord.createdAt),
                    SortDescriptor(\DiagnosticRecord.id)
                ]
            )
            descriptor.fetchLimit = Self.diagnosticLinkScanBatchSize
            descriptor.fetchOffset = offset
            let batch = try context.fetch(descriptor)
            guard !batch.isEmpty else { break }
            recordIDs.formUnion(batch.compactMap(\.launchRecordId))
            if batch.count < Self.diagnosticLinkScanBatchSize { break }
            offset += batch.count
        }
        return recordIDs
    }
}

@ModelActor
actor SteamLaunchHistoryMaintenanceWorker {
    func pruneCompletedHistory(
        environmentIdentity: SteamEnvironmentIdentity,
        currentAppSessionID: String
    ) throws -> Int {
        try SteamLaunchReadinessRepository().pruneCompletedHistory(
            in: modelContext,
            environmentIdentity: environmentIdentity,
            currentAppSessionID: currentAppSessionID
        )
    }
}

@MainActor
final class SteamLaunchHistoryMaintenanceScheduler {
    private struct Request: Sendable {
        let modelContainer: ModelContainer
        let environmentIdentity: SteamEnvironmentIdentity
        let currentAppSessionID: String
        let onFailure: @MainActor @Sendable (Error) -> Void
    }

    private var activeRequestID: UUID?
    private var activeTask: Task<Void, Never>?
    private var pendingRequest: Request?

    @discardableResult
    func schedule(
        modelContainer: ModelContainer,
        environmentIdentity: SteamEnvironmentIdentity,
        currentAppSessionID: String,
        onFailure: @escaping @MainActor @Sendable (Error) -> Void
    ) -> Bool {
        let request = Request(
            modelContainer: modelContainer,
            environmentIdentity: environmentIdentity,
            currentAppSessionID: currentAppSessionID,
            onFailure: onFailure
        )
        guard activeTask == nil else {
            pendingRequest = request
            return false
        }
        start(request)
        return true
    }

    private func start(_ request: Request) {
        let requestID = UUID()
        activeRequestID = requestID
        activeTask = Task.detached(priority: .utility) { [weak self] in
            let failure: Error?
            do {
                // SwiftData binds a newly created ModelContext to the executor
                // that creates it. Construct the @ModelActor only after leaving
                // MainActor so a large first retention pass cannot run on UI.
                let worker = SteamLaunchHistoryMaintenanceWorker(
                    modelContainer: request.modelContainer
                )
                _ = try await worker.pruneCompletedHistory(
                    environmentIdentity: request.environmentIdentity,
                    currentAppSessionID: request.currentAppSessionID
                )
                failure = nil
            } catch is CancellationError {
                failure = nil
            } catch {
                failure = Task.isCancelled ? nil : error
            }
            await self?.finish(
                requestID,
                failure: failure,
                onFailure: request.onFailure
            )
        }
    }

    private func finish(
        _ requestID: UUID,
        failure: Error?,
        onFailure: @MainActor @Sendable (Error) -> Void
    ) {
        guard activeRequestID == requestID else { return }
        if let failure {
            onFailure(failure)
        }
        activeRequestID = nil
        activeTask = nil
        guard let pendingRequest else { return }
        self.pendingRequest = nil
        start(pendingRequest)
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        activeRequestID = nil
        pendingRequest = nil
    }
}

@MainActor
final class SteamPrefixReadinessResolver {
    private let pathManager: PathManager
    private let prefixManager: PrefixManager
    private let steamManager: SteamManager
    private let steamSessionStateInspector: SteamSessionStateInspector
    private let fileManager: FileManager

    init(
        pathManager: PathManager,
        prefixManager: PrefixManager,
        steamManager: SteamManager,
        steamSessionStateInspector: SteamSessionStateInspector = SteamSessionStateInspector(),
        fileManager: FileManager = .default
    ) {
        self.pathManager = pathManager
        self.prefixManager = prefixManager
        self.steamManager = steamManager
        self.steamSessionStateInspector = steamSessionStateInspector
        self.fileManager = fileManager
    }

    func resolve(
        hasSteamReferences: Bool,
        runtimeExecutable: URL? = nil,
        runtimeManifest: RuntimeManifest? = nil,
        runtimeCapability: WindowsRuntimeCapability? = nil,
        rendererPolicySelection: SteamRendererPolicySelection = .d3dMetalNVIDIA,
        videoMemorySelection: SteamVideoMemorySelection = .automatic
    ) -> SetupReadiness {
        let root: URL
        do {
            root = try currentRootForReadiness()
        } catch PathManagerError.rootNotConfigured {
            return SetupReadiness(
                hasSteamPrefix: false,
                hasSteamExecutable: false,
                hasSteamReferences: hasSteamReferences,
                steamPrefixURL: nil,
                steamExecutableURL: nil
            )
        } catch let error as PathManagerError {
            return SetupReadiness(
                hasSteamPrefix: false,
                hasSteamExecutable: false,
                hasSteamReferences: hasSteamReferences,
                steamPrefixURL: nil,
                steamExecutableURL: nil,
                rootIssue: error
            )
        } catch {
            let rootIssue = PathManagerError.validationFailed(
                pathManager.rootURL,
                forgePlayTechnicalErrorSummary(error)
            )
            return SetupReadiness(
                hasSteamPrefix: false,
                hasSteamExecutable: false,
                hasSteamReferences: hasSteamReferences,
                steamPrefixURL: nil,
                steamExecutableURL: nil,
                rootIssue: rootIssue
            )
        }

        let prefix = root.appending(path: ForgePlayPathRole.steamSharedPrefix.rawValue, directoryHint: .isDirectory)
        let steamExecutable = prefix.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
        // Readiness is a projection only. Recovery and recursive cleanup belong
        // to the explicitly coordinated managed-storage maintenance phase; a
        // SwiftUI refresh must never acquire mutation leases or delete files.
        let prefixStatus = resolvedSteamPrefixStatus(prefix)
        // Concrete launch inputs are intentionally projected independently of
        // metadata/architecture diagnostics. Otherwise a stale prefix.json can
        // hide a perfectly safe existing Steam installation and turn a repair
        // recommendation into an execution gate.
        let hasSteamPrefixDirectory = FileSystemItemPolicy.isNonSymlinkDirectory(
            prefix,
            fileManager: fileManager
        )
        // An empty managed placeholder is not an installed Wine prefix. Keep a
        // concrete but diagnostically damaged prefix visible, however, so its
        // existing steam.exe can still take the operational launch path.
        let hasSteamPrefix = hasSteamPrefixDirectory &&
            (prefixStatus.isUsable || prefixStatus.issue != nil)
        let hasSteamExecutable = hasSteamPrefix &&
            FileSystemItemPolicy.isRegularNonSymlinkFile(
                steamExecutable,
                fileManager: fileManager
            )
        let prefixMetadata = hasSteamPrefix
            ? try? prefixManager.loadMetadata(at: prefix)
            : nil
        let steamSessionInspection = hasSteamPrefix
            ? steamSessionStateInspector.inspect(prefix: prefix)
            : .unavailable
        let rendererInspection: SteamRendererPolicyInspection?
        if hasSteamPrefix, let runtimeExecutable, let runtimeCapability {
            rendererInspection = steamManager.inspectSteamRendererPolicyForReadiness(
                prefix: prefix,
                runtimeExecutable: runtimeExecutable,
                runtimeCapability: runtimeCapability,
                selection: rendererPolicySelection,
                videoMemorySizeMB: videoMemorySelection.resolvedSizeMB()
            )
        } else {
            rendererInspection = nil
        }
        let runtimeCompatibilityInspection: PrefixRuntimeCompatibilityInspection?
        if let runtimeManifest, hasSteamPrefix {
            runtimeCompatibilityInspection = prefixManager
                .inspectSteamSharedPrefixRuntimeCompatibility(
                    manifest: runtimeManifest
                )
        } else {
            runtimeCompatibilityInspection = nil
        }

        return SetupReadiness(
            hasSteamPrefix: hasSteamPrefix,
            hasSteamExecutable: hasSteamExecutable,
            hasSteamReferences: hasSteamReferences,
            steamPrefixURL: prefix,
            steamExecutableURL: steamExecutable,
            steamPrefixIssue: prefixStatus.issue,
            runtimeCompatibilityInspection: runtimeCompatibilityInspection,
            rendererInspection: rendererInspection,
            steamSessionInspection: steamSessionInspection,
            steamEnvironmentCreatedAt: prefixMetadata?.createdAt,
            steamEnvironmentGenerationID: prefixMetadata?.environmentGenerationID
        )
    }

    func currentSteamEnvironmentIdentity() -> SteamEnvironmentIdentity {
        guard let root = try? currentRootForReadiness() else {
            return SteamEnvironmentIdentity(generationID: nil, createdAt: nil)
        }
        let prefix = root.appending(
            path: ForgePlayPathRole.steamSharedPrefix.rawValue,
            directoryHint: .isDirectory
        )
        guard resolvedSteamPrefixStatus(prefix).isUsable,
              let metadata = try? prefixManager.loadMetadata(at: prefix) else {
            return SteamEnvironmentIdentity(generationID: nil, createdAt: nil)
        }
        return SteamEnvironmentIdentity(
            generationID: metadata.environmentGenerationID,
            createdAt: metadata.createdAt
        )
    }

    private func currentRootForReadiness() throws -> URL {
        guard let root = pathManager.rootURL else {
            throw PathManagerError.rootNotConfigured
        }
        try pathManager.validateExistingManagedRoot(root)
        return root
    }

    private func resolvedSteamPrefixStatus(_ prefix: URL?) -> (isUsable: Bool, issue: PrefixUsabilityError?) {
        guard let prefix else {
            return (false, nil)
        }
        guard fileManager.fileExists(atPath: prefix.path) else {
            return (false, nil)
        }
        do {
            if try prefixManager.isUninitializedPrefixPlaceholder(at: prefix) {
                return (false, nil)
            }
            try prefixManager.validateUsablePrefix(at: prefix)
            return (true, nil)
        } catch let error as PrefixUsabilityError {
            return (false, error)
        } catch {
            return (
                false,
                PrefixUsabilityError.invalidMetadata(
                    prefix.appending(path: "prefix.json"),
                    forgePlayTechnicalErrorSummary(error)
                )
            )
        }
    }
}
