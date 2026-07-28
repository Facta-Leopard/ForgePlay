import Foundation

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
        switch steamPrefixState {
        case .launchReady, .rendererNeedsApply:
            true
        case .rootNotConfigured,
             .rootUnavailable,
             .prefixMissing,
             .prefixInvalid,
             .steamMissing,
             .runtimeMigrationRequired,
             .rendererUnverified,
             .rendererNeedsRepair,
             .runtimeUnavailable:
            false
        }
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

    func withSteamLaunchRecords(
        _ records: [LaunchRecord],
        currentAppSessionID: String? = nil
    ) -> SetupReadiness {
        let currentRecords = SteamLaunchRecordLookup.currentEnvironmentRecords(
            from: records,
            environmentGenerationID: steamEnvironmentGenerationID,
            environmentCreatedAt: steamEnvironmentCreatedAt
        )
        let currentSessionRecords = currentAppSessionID.map { appSessionID in
            currentRecords.filter { $0.hostAppSessionID == appSessionID }
        } ?? currentRecords
        let latest = currentSessionRecords.first
        let libraryAppSessionIDs = Set(currentRecords.compactMap { record -> String? in
            guard record.steamUIVerificationState == .rendered,
                  record.steamUISurface == .library,
                  let appSessionID = record.hostAppSessionID,
                  !appSessionID.isEmpty else {
                return nil
            }
            return appSessionID
        })
        let hasLibraryVerification = currentRecords.contains {
            $0.steamUIVerificationState == .rendered && $0.steamUISurface == .library
        }
        var updated = withSteamUIVerification(latest?.steamUIVerificationState ?? .notRun)
        updated.steamUISurface = latest?.steamUISurface
        if libraryAppSessionIDs.count >= 2 {
            updated.steamSessionContinuityState = .libraryVerifiedAfterRelaunch
        } else if hasLibraryVerification {
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

enum SteamLaunchRecordLookup {
    static func stateFingerprint(from records: [LaunchRecord]) -> String {
        records
            .filter { $0.commandKind == "launchSteam" && $0.prefixId == PrefixIdentifier.steamShared }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(32)
            .map {
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

    static func latestSteamUIVerificationState(from records: [LaunchRecord]) -> SteamUIVerificationState {
        latestSteamLaunchRecord(from: records)?.steamUIVerificationState ?? .notRun
    }
}

@MainActor
final class SteamPrefixReadinessResolver {
    private let pathManager: PathManager
    private let prefixManager: PrefixManager
    private let steamManager: SteamManager
    private let steamPrefixService: SteamPrefixService
    private let steamSessionStateInspector: SteamSessionStateInspector
    private let fileManager: FileManager

    init(
        pathManager: PathManager,
        prefixManager: PrefixManager,
        steamManager: SteamManager,
        steamPrefixService: SteamPrefixService,
        steamSessionStateInspector: SteamSessionStateInspector = SteamSessionStateInspector(),
        fileManager: FileManager = .default
    ) {
        self.pathManager = pathManager
        self.prefixManager = prefixManager
        self.steamManager = steamManager
        self.steamPrefixService = steamPrefixService
        self.steamSessionStateInspector = steamSessionStateInspector
        self.fileManager = fileManager
    }

    func resolve(
        hasSteamReferences: Bool,
        runtimeExecutable: URL? = nil,
        rendererPolicySelection: SteamRendererPolicySelection = .d3dMetal,
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
        let prefixStatus: (isUsable: Bool, issue: PrefixUsabilityError?)
        do {
            try steamPrefixService.cleanupInterruptedReplacementArtifacts(at: prefix)
            prefixStatus = resolvedSteamPrefixStatus(prefix)
        } catch is SteamPrefixLifecycleError {
            prefixStatus = resolvedSteamPrefixStatus(prefix)
        } catch {
            prefixStatus = (
                false,
                PrefixUsabilityError.invalidMetadata(
                    prefix.appending(path: "prefix.json"),
                    "Interrupted Steam environment cleanup failed: \(forgePlayTechnicalErrorSummary(error))"
                )
            )
        }
        let hasSteamExecutable = prefixStatus.isUsable
            ? FileSystemItemPolicy.isRegularNonSymlinkFile(steamExecutable, fileManager: fileManager)
            : false
        let prefixMetadata = prefixStatus.isUsable ? try? prefixManager.loadMetadata(at: prefix) : nil
        let steamSessionInspection = prefixStatus.isUsable
            ? steamSessionStateInspector.inspect(prefix: prefix)
            : .unavailable
        let rendererInspection = runtimeExecutable.map {
            steamManager.inspectSteamRendererPolicy(
                prefix: prefix,
                runtimeExecutable: $0,
                selection: rendererPolicySelection,
                videoMemorySizeMB: videoMemorySelection.resolvedSizeMB()
            )
        }
        let runtimeCompatibilityInspection: PrefixRuntimeCompatibilityInspection?
        if let runtimeExecutable, prefixStatus.isUsable {
            runtimeCompatibilityInspection = prefixManager
                .inspectSteamSharedPrefixRuntimeCompatibility(runtimeExecutable: runtimeExecutable)
        } else {
            runtimeCompatibilityInspection = nil
        }

        return SetupReadiness(
            hasSteamPrefix: prefixStatus.isUsable,
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
