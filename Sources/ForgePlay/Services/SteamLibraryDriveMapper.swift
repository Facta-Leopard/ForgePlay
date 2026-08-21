import Foundation

/// Defines whether the caller's authorized selections are a complete storage
/// inventory or only a direct subtree capability used by one launch. A direct
/// subtree must never be promoted to its unselected parent, and its absence
/// from the drive/library inventory is not evidence that older ForgePlay-owned
/// mappings are stale.
enum SteamLibraryDriveReconciliationScope: Hashable, Sendable {
    case authoritativeStorageInventory
    case preservingUnrepresentedState
}

final class SteamLibraryDriveMapper {
    private static let bridgeDirectoryName = ".forgeplay-library-drives"
    private static let bridgeLibraryDirectoryName = "SteamLibrary"
    private static let assignmentFileName = ".assignment-v1.json"
    private static let registrationManifestFileName =
        ".steam-library-registrations-v1.json"

    private enum DriveLinkOwnership: String, Codable, Hashable {
        case forgePlay
        case external
    }

    private struct DriveAssignment: Codable, Hashable {
        static let currentVersion = 3
        static let supportedVersions = 1...currentVersion

        var version: Int
        var storageIdentity: String
        var lastKnownPath: String
        var driveLinkOwnership: DriveLinkOwnership?
        /// `true` means the bookmark-backed storage is temporarily unavailable
        /// but the user has not disconnected it. This reservation keeps the
        /// stable drive identity and ForgePlay-owned Steam registration intact
        /// until access is restored or the mount is explicitly removed.
        var isReservedOnly: Bool?
    }

    private struct OwnedRegistration: Codable, Hashable {
        var normalizedWindowsPath: String
        var driveRootStorageIdentity: String
        var canonicalDriveRootPath: String
        var canonicalLibraryPath: String
        var contentID: String
    }

    private struct RegistrationManifest: Codable, Hashable {
        static let currentVersion = 3

        var version: Int
        var ownedRegistrations: [OwnedRegistration]

        static let empty = RegistrationManifest(
            version: currentVersion,
            ownedRegistrations: []
        )
    }

    private struct LegacyRegistrationManifest: Decodable {
        var version: Int
        var ownedWindowsPaths: [String]
    }

    private struct ManifestVersion: Decodable {
        var version: Int
    }

    private struct NormalizedDriveSource: Hashable {
        var authorizedRootURL: URL
        var libraryURL: URL
    }

    private let fileManager: FileManager
    private let storageIdentityProvider: ((URL) -> String)?

    init(
        fileManager: FileManager = .default,
        storageIdentityProvider: ((URL) -> String)? = nil
    ) {
        self.fileManager = fileManager
        self.storageIdentityProvider = storageIdentityProvider
    }

    func prepareDriveLinks(
        prefix: URL,
        libraryRoots: [URL],
        reservedLibraryRoots: [URL] = []
    ) throws -> [SteamLibraryDriveMapping] {
        // This legacy entry point is the strict existing-library contract.
        // Callers that authorize blank storage must use
        // `prepareStorageDriveLinks` instead.
        return try prepareDriveLinks(
            prefix: prefix,
            sources: libraryRoots.map {
                SteamLibraryDriveSource(
                    authorizedRootURL: $0,
                    libraryURL: $0
                )
            },
            reservedDriveRoots: reservedLibraryRoots
        )
    }

    func prepareDriveLinks(
        prefix: URL,
        sources: [SteamLibraryDriveSource],
        reservedDriveRoots: [URL] = []
    ) throws -> [SteamLibraryDriveMapping] {
        // Preserve the strict behavior of the existing-library API.
        let normalizedSources = normalizedDriveSources(sources)
        try validateAuthorizedDriveRootsBeforeMutation(
            normalizedSelectedDriveRoots(
                normalizedSources.map(\.authorizedRootURL)
            )
        )
        try validateDriveSourcesBeforeMutation(normalizedSources)
        for source in normalizedSources {
            _ = try steamLibraryContentID(
                at: source.libraryURL.standardizedFileURL
            )
        }
        return try prepareStorageDriveLinks(
            prefix: prefix,
            authorizedStorageRoots: sources.map(\.authorizedRootURL),
            sources: sources,
            reservedDriveRoots: reservedDriveRoots
        ).libraryMappings
    }

    /// Exposes every authorized root as a direct Wine drive. Existing Steam
    /// libraries below those roots are an optional, independently validated
    /// input used only for `libraryfolders.vdf` registration.
    func prepareStorageDriveLinks(
        prefix: URL,
        authorizedStorageRoots: [URL],
        sources: [SteamLibraryDriveSource],
        reservedDriveRoots: [URL] = [],
        reconciliationScope: SteamLibraryDriveReconciliationScope =
            .authoritativeStorageInventory
    ) throws -> SteamStorageDrivePreparation {
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        guard FileSystemItemPolicy.isNonSymlinkDirectory(dosdevices, fileManager: fileManager) else {
            throw SteamLibraryDriveBridgeError.dosdevicesUnavailable(dosdevices)
        }
        let bridgeDirectory = prefix.appending(
            path: Self.bridgeDirectoryName,
            directoryHint: .isDirectory
        )
        let activeSources = normalizedDriveSources(sources)
        let activeDriveRoots = normalizedSelectedDriveRoots(
            authorizedStorageRoots + activeSources.map(\.authorizedRootURL)
        )
        try validateAuthorizedDriveRootsBeforeMutation(activeDriveRoots)
        try validateDriveSourcesBeforeMutation(activeSources)
        let registrationSources = Set(activeSources.filter {
            isSteamLibraryRegistrationReady(at: $0.libraryURL)
        })

        // This directory owns stable drive-letter assignment metadata only.
        // The actual Wine drive always points directly at the user-authorized
        // macOS folder so Steam observes the external volume, capacity, and
        // filesystem rather than the prefix's internal storage.
        do {
            try fileManager.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true)
            try FileSystemItemPolicy.requireNonSymlinkDirectory(bridgeDirectory, fileManager: fileManager)
        } catch {
            throw SteamLibraryDriveBridgeError.bridgeDirectoryUnavailable(bridgeDirectory)
        }

        let activeIdentities = Set(activeDriveRoots.map(storageIdentity(for:)))
        let inactiveReservedRoots = normalizedSelectedDriveRoots(reservedDriveRoots).filter {
            !activeIdentities.contains(storageIdentity(for: $0))
        }
        if reconciliationScope == .authoritativeStorageInventory {
            try removeOrphanedBridgeReservations(
                dosdevices: dosdevices,
                bridgeDirectory: bridgeDirectory,
                requestedRoots: inactiveReservedRoots + activeDriveRoots
            )
        }

        var mappings: [SteamLibraryDriveMapping] = []
        var pendingMappings: [SteamLibraryDriveMapping] = []
        var activeDriveLetters = Set<String>()
        var usedLetters = Set<String>()
        for libraryRoot in inactiveReservedRoots {
            guard let letter = try driveLetter(
                for: libraryRoot,
                dosdevices: dosdevices,
                bridgeDirectory: bridgeDirectory,
                usedLetters: &usedLetters
            ) else {
                throw SteamLibraryDriveBridgeError.noAvailableDriveLetter(libraryRoot)
            }
            let bridgeRoot = bridgeDirectory.appending(
                path: letter,
                directoryHint: .isDirectory
            )
            let existingOwnership = try readAssignment(at: bridgeRoot)?
                .driveLinkOwnership ?? .external
            _ = try prepareBridgeRoot(
                for: libraryRoot,
                driveLetter: letter,
                bridgeDirectory: bridgeDirectory,
                driveLinkOwnership: existingOwnership,
                isReservedOnly: true
            )
        }
        for authorizedRoot in activeDriveRoots {
            guard FileSystemItemPolicy.isNonSymlinkDirectory(
                authorizedRoot,
                fileManager: fileManager
            ) else {
                throw SteamLibraryDriveBridgeError.libraryRootUnavailable(authorizedRoot)
            }
            guard let letter = try driveLetter(
                for: authorizedRoot,
                dosdevices: dosdevices,
                bridgeDirectory: bridgeDirectory,
                usedLetters: &usedLetters
            ) else {
                throw SteamLibraryDriveBridgeError.noAvailableDriveLetter(authorizedRoot)
            }
            let bridgeRootURL = bridgeDirectory.appending(path: letter, directoryHint: .isDirectory)
            let existingAssignment = try readAssignment(at: bridgeRootURL)
            let existingOwnership = existingAssignment?.driveLinkOwnership ?? .external
            let previousDirectTarget = try previousManagedDirectTarget(
                at: bridgeRootURL,
                for: authorizedRoot
            )
            let bridgeRoot = try prepareBridgeRoot(
                for: authorizedRoot,
                driveLetter: letter,
                bridgeDirectory: bridgeDirectory,
                driveLinkOwnership: existingOwnership,
                isReservedOnly: false
            )
            let installedOwnership = try installDriveLink(
                dosdevices.appending(path: "\(letter):"),
                target: authorizedRoot,
                replacingLegacyBridge: bridgeRoot,
                bridgeDirectory: bridgeDirectory,
                replacingPreviousDirectTarget: previousDirectTarget,
                ownsExistingDirectLink: existingOwnership == .forgePlay
            )
            try writeAssignment(
                for: authorizedRoot,
                at: bridgeRoot,
                driveLinkOwnership: installedOwnership,
                isReservedOnly: false
            )
            activeDriveLetters.insert(letter)
            let sourcesForDrive = activeSources
                .filter {
                    storageIdentity(for: $0.authorizedRootURL) ==
                        storageIdentity(for: authorizedRoot)
                }
                .sorted {
                    $0.libraryURL.path.localizedStandardCompare(
                        $1.libraryURL.path
                    ) == .orderedAscending
                }
            for source in sourcesForDrive {
                let libraryRoot = source.libraryURL
                guard FileSystemItemPolicy.isNonSymlinkDirectory(
                    libraryRoot,
                    fileManager: fileManager
                ) else {
                    throw SteamLibraryDriveBridgeError.libraryRootUnavailable(libraryRoot)
                }
                let mapping = SteamLibraryDriveMapping(
                    driveLetter: letter,
                    macLibraryURL: libraryRoot,
                    windowsLibraryPath: try windowsLibraryPath(
                        driveLetter: letter,
                        authorizedRoot: authorizedRoot,
                        libraryRoot: libraryRoot
                    ),
                    macDriveRootURL: authorizedRoot
                )
                if registrationSources.contains(source) {
                    mappings.append(mapping)
                } else {
                    pendingMappings.append(mapping)
                }
            }
        }
        if reconciliationScope == .authoritativeStorageInventory {
            try removeInactiveManagedBridges(
                dosdevices: dosdevices,
                bridgeDirectory: bridgeDirectory,
                activeDriveLetters: activeDriveLetters,
                reservedDriveLetters: usedLetters
            )
        }
        return SteamStorageDrivePreparation(
            externalStorageRoots: activeDriveRoots,
            libraryMappings: mappings,
            pendingLibraryMappings: pendingMappings
        )
    }

    nonisolated static func libraryRootCandidate(from game: SteamGame) -> URL {
        normalizedLaunchLibraryRoot(URL(fileURLWithPath: game.libraryPath, isDirectory: true), installDir: game.installDir)
    }

    nonisolated static func normalizedLaunchLibraryRoot(_ url: URL, installDir: String? = nil) -> URL {
        var normalized = url.standardizedFileURL
        if let installDir,
           normalized.lastPathComponent.caseInsensitiveCompare(installDir) == .orderedSame,
           normalized.deletingLastPathComponent().lastPathComponent.lowercased() == "common",
           normalized.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.lowercased() == "steamapps" {
            normalized.deleteLastPathComponent()
            normalized.deleteLastPathComponent()
            normalized.deleteLastPathComponent()
            return normalized
        }
        if normalized.lastPathComponent.lowercased() == "common",
           normalized.deletingLastPathComponent().lastPathComponent.lowercased() == "steamapps" {
            normalized.deleteLastPathComponent()
            normalized.deleteLastPathComponent()
            return normalized
        }
        if normalized.lastPathComponent.lowercased() == "steamapps" {
            normalized.deleteLastPathComponent()
            return normalized
        }
        return normalized
    }

    nonisolated static func macURL(fromSteamLibraryPath path: String, prefix: URL?) -> URL {
        if let validated = validatedMacURL(
            fromSteamLibraryPath: path,
            prefix: prefix
        ) {
            return validated
        }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return URL(fileURLWithPath: normalized)
    }

    nonisolated static func validatedMacURL(
        fromSteamLibraryPath path: String,
        prefix: URL?
    ) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
              !normalized.contains("\0") else {
            return nil
        }

        guard normalized.count >= 2,
              normalized[normalized.index(normalized.startIndex, offsetBy: 1)] == ":" else {
            guard normalized.hasPrefix("/"),
                  !normalized.hasPrefix("//"),
                  validatedWindowsPathComponents(in: normalized) != nil else {
                return nil
            }
            return URL(
                fileURLWithPath: normalized,
                isDirectory: true
            ).resolvingSymlinksInPath().standardizedFileURL
        }

        let drive = normalized.prefix(1).uppercased()
        guard drive.count == 1,
              let driveScalar = drive.unicodeScalars.first,
              UnicodeScalar("A").value...UnicodeScalar("Z").value ~=
                driveScalar.value else {
            return nil
        }
        let remainderStart = normalized.index(normalized.startIndex, offsetBy: 2)
        let remainder = String(normalized[remainderStart...])
        guard let components = validatedWindowsPathComponents(in: remainder) else {
            return nil
        }

        let mappedRoot: URL
        if let prefix,
           let configuredRoot = mappedMacRoot(forDrive: drive, prefix: prefix) {
            mappedRoot = configuredRoot
        } else if drive == "C", let prefix {
            mappedRoot = prefix
                .appending(path: "drive_c", directoryHint: .isDirectory)
        } else if drive == "Z" {
            mappedRoot = URL(fileURLWithPath: "/", isDirectory: true)
        } else {
            return nil
        }

        let candidate = components.reduce(mappedRoot) {
            $0.appending(path: $1, directoryHint: .isDirectory)
        }
        let resolvedRoot = mappedRoot.resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
            .standardizedFileURL
        guard isURL(resolvedCandidate, containedBy: resolvedRoot) else {
            return nil
        }
        return resolvedCandidate
    }

    private nonisolated static func validatedWindowsPathComponents(
        in path: String
    ) -> [String]? {
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard components.allSatisfy({
            !$0.isEmpty &&
                $0 != "." &&
                $0 != ".." &&
                !$0.contains(":") &&
                !$0.contains("\0")
        }) else {
            return nil
        }
        return components
    }

    private nonisolated static func isURL(
        _ candidate: URL,
        containedBy root: URL
    ) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count &&
            Array(candidateComponents.prefix(rootComponents.count)) ==
                rootComponents
    }

    /// Synchronizes only ForgePlay-owned library registrations while Steam is
    /// stopped. Existing user/Steam entries are preserved, and an entry that
    /// already existed before ForgePlay saw it is never claimed as ours.
    func synchronizeDriveMappingsWithSteam(
        prefix: URL,
        mappings: [SteamLibraryDriveMapping],
        pendingMappings: [SteamLibraryDriveMapping] = [],
        reconciliationScope: SteamLibraryDriveReconciliationScope =
            .authoritativeStorageInventory
    ) throws {
        // A direct `steamapps` capability authorizes process access only. With
        // no independently authorized storage mapping there is intentionally
        // nothing to reconcile, so even reading and rewriting unrelated Steam
        // registration state would exceed this request's ownership boundary.
        if reconciliationScope == .preservingUnrepresentedState,
           mappings.isEmpty,
           pendingMappings.isEmpty {
            return
        }
        let bridgeDirectory = prefix.appending(
            path: Self.bridgeDirectoryName,
            directoryHint: .isDirectory
        )
        let manifestURL = bridgeDirectory.appending(
            path: Self.registrationManifestFileName,
            directoryHint: .notDirectory
        )
        let previousManifest = try loadRegistrationManifest(at: manifestURL)
        let previousOwnedByPath = Dictionary(
            previousManifest.ownedRegistrations.map {
                ($0.normalizedWindowsPath, $0)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        let reservedStorageIdentities = try reservedOnlyStorageIdentities(
            in: bridgeDirectory
        )
        guard !mappings.isEmpty ||
                !pendingMappings.isEmpty ||
                !previousOwnedByPath.isEmpty else { return }

        let steamDirectory = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        guard FileSystemItemPolicy.isNonSymlinkDirectory(
            steamDirectory,
            fileManager: fileManager
        ) else {
            throw SteamLibraryDriveBridgeError.libraryFoldersUnavailable(steamDirectory)
        }
        let steamApps = steamDirectory.appending(
            path: "steamapps",
            directoryHint: .isDirectory
        )
        do {
            try fileManager.createDirectory(at: steamApps, withIntermediateDirectories: true)
            try FileSystemItemPolicy.requireNonSymlinkDirectory(
                steamApps,
                fileManager: fileManager
            )
        } catch {
            throw SteamLibraryDriveBridgeError.libraryFoldersUnavailable(steamApps)
        }

        let authoritativeURL = steamApps.appending(
            path: "libraryfolders.vdf",
            directoryHint: .notDirectory
        )
        let compatibilityURL = steamDirectory
            .appending(path: "config", directoryHint: .isDirectory)
            .appending(path: "libraryfolders.vdf", directoryHint: .notDirectory)
        var targetURLs = [authoritativeURL]
        if fileManager.fileExists(atPath: compatibilityURL.path) {
            targetURLs.append(compatibilityURL)
        }

        var document = try mergedLibraryFoldersDocument(from: targetURLs)
        guard var libraryFolders = document["libraryfolders"]?.objectValue else {
            throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                authoritativeURL,
                "missing libraryfolders object"
            )
        }
        let originalLibraryFolders = libraryFolders

        let activeByPath = Dictionary(
            mappings.map { (normalizedWindowsPath($0.windowsLibraryPath), $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        let activePaths = Set(activeByPath.keys)
        let pendingByPath = Dictionary(
            pendingMappings.compactMap { mapping -> (String, SteamLibraryDriveMapping)? in
                let path = normalizedWindowsPath(mapping.windowsLibraryPath)
                guard activeByPath[path] == nil else { return nil }
                return (path, mapping)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        let retainedPendingOwnedByPath = try Dictionary(
            uniqueKeysWithValues: previousOwnedByPath.compactMap {
                path,
                ownership -> (String, OwnedRegistration)? in
                guard let mapping = pendingByPath[path],
                      registrationTarget(
                          ownership,
                          matches: ownedRegistration(
                              for: mapping,
                              contentID: ownership.contentID
                          )
                      ),
                      try registrationOwnershipMatchesEveryExistingCopy(
                          ownership,
                          at: targetURLs
                      ) else {
                    return nil
                }
                return (path, ownership)
            }
        )
        let retainedReservedOwnedByPath = try Dictionary(
            uniqueKeysWithValues: previousOwnedByPath.compactMap {
                path,
                ownership -> (String, OwnedRegistration)? in
                guard reservedStorageIdentities.contains(
                    ownership.driveRootStorageIdentity
                ),
                try registrationOwnershipMatchesEveryExistingCopy(
                    ownership,
                    at: targetURLs
                ) else {
                    return nil
                }
                return (path, ownership)
            }
        )
        var retainedAuthoritativeOwnedByPath = retainedPendingOwnedByPath
        for (path, ownership) in retainedReservedOwnedByPath {
            retainedAuthoritativeOwnedByPath[path] = ownership
        }
        let retainedOwnedByPath =
            reconciliationScope == .preservingUnrepresentedState
                ? previousOwnedByPath
                : retainedAuthoritativeOwnedByPath
        let protectedPaths = activePaths.union(retainedOwnedByPath.keys)
        let removableOwnedPaths: Set<String> = try Set(
            previousOwnedByPath.values.compactMap { ownership in
                guard !protectedPaths.contains(ownership.normalizedWindowsPath),
                      try registrationOwnershipMatchesEveryExistingCopy(
                          ownership,
                          at: targetURLs
                      ) else {
                    return nil
                }
                return ownership.normalizedWindowsPath
            }
        )
        var removalCandidates = Set<String>()
        libraryFolders = libraryFolders.filter { _, value in
            guard let path = value.objectValue?["path"]?.stringValue else {
                return true
            }
            let normalizedPath = normalizedWindowsPath(path)
            guard removableOwnedPaths.contains(normalizedPath),
                  let previousOwnership = previousOwnedByPath[normalizedPath],
                  registrationEntry(
                    value,
                    matches: previousOwnership
                  ) else {
                return true
            }
            removalCandidates.insert(normalizedPath)
            return false
        }

        let registeredEntriesByPath = Dictionary(
            libraryFolders.values.compactMap { value -> (String, VDFValue)? in
                guard let path = value.objectValue?["path"]?.stringValue else {
                    return nil
                }
                return (normalizedWindowsPath(path), value)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        var registeredCanonicalLibraryPaths = Set(
            libraryFolders.values.compactMap { value in
                value.objectValue?["path"]?.stringValue.flatMap {
                    canonicalExistingLibraryPath(
                        fromWindowsPath: $0,
                        prefix: prefix
                    )
                }
            }
        )
        var registeredPaths = Set(registeredEntriesByPath.keys)
        var nextOwnedByPath = retainedOwnedByPath
        for path in activePaths.sorted() {
            guard let mapping = activeByPath[path] else {
                continue
            }
            if let existingEntry = registeredEntriesByPath[path] {
                if let previousOwnership = previousOwnedByPath[path],
                   registrationEntry(
                       existingEntry,
                       matches: previousOwnership
                   ),
                   try registrationOwnershipMatchesEveryExistingCopy(
                       previousOwnership,
                       at: targetURLs
                   ) {
                    let currentTarget = ownedRegistration(
                        for: mapping,
                        contentID: previousOwnership.contentID
                    )
                    guard registrationTarget(
                        previousOwnership,
                        matches: currentTarget
                    ) else {
                        continue
                    }
                    let contentID = try steamLibraryContentID(
                        for: mapping
                    )
                    let desiredOwnership = ownedRegistration(
                        for: mapping,
                        contentID: contentID
                    )
                    for (key, value) in libraryFolders {
                        guard let existingPath = value.objectValue?["path"]?
                                .stringValue,
                              normalizedWindowsPath(existingPath) == path
                        else { continue }
                        libraryFolders[key] = libraryFolderEntry(
                            updating: value,
                            ownership: desiredOwnership
                        )
                    }
                    nextOwnedByPath[path] = desiredOwnership
                }
                continue
            }
            let canonicalLibraryPath = canonicalLibraryPath(for: mapping)
            guard !registeredCanonicalLibraryPaths.contains(
                canonicalLibraryPath
            ) else {
                continue
            }
            guard registeredPaths.insert(path).inserted else { continue }
            let contentID = try steamLibraryContentID(for: mapping)
            let desiredOwnership = ownedRegistration(
                for: mapping,
                contentID: contentID
            )
            libraryFolders[nextLibraryIndex(in: libraryFolders)] =
                libraryFolderEntry(
                    for: mapping,
                    ownership: desiredOwnership
                )
            nextOwnedByPath[path] = desiredOwnership
            registeredCanonicalLibraryPaths.insert(canonicalLibraryPath)
        }
        let retainedPaths = Set(libraryFolders.values.compactMap { value in
            value.objectValue?["path"]?.stringValue.map(normalizedWindowsPath)
        })
        let removedPaths = removalCandidates.subtracting(retainedPaths)
        document["libraryfolders"] = .object(libraryFolders)

        let shouldWriteLibraryFolders = libraryFolders != originalLibraryFolders
        let nextOwnedRegistrations = nextOwnedByPath.values.sorted {
            $0.normalizedWindowsPath < $1.normalizedWindowsPath
        }
        let nextManifest = RegistrationManifest(
            version: RegistrationManifest.currentVersion,
            ownedRegistrations: nextOwnedRegistrations
        )
        // Schema migration is coupled to an actual ownership transition. An
        // unchanged v2 manifest is still valid readback and must remain
        // byte-stable while its identity marker is transiently pending.
        let shouldWriteManifest =
            previousManifest.ownedRegistrations != nextOwnedRegistrations
        guard shouldWriteLibraryFolders || shouldWriteManifest else {
            // Exact Steam-owned readback and transient pending identities are
            // semantic no-ops. Preserve Steam's formatting/comments and the
            // ownership manifest byte-for-byte instead of rewriting either.
            return
        }

        let serializedData = shouldWriteLibraryFolders
            ? Data(VDFSerializer().serialize(document).utf8)
            : nil
        let originals = shouldWriteLibraryFolders
            ? try targetURLs.map { url in
                (url, try existingSafeLibraryFoldersData(at: url))
            }
            : []
        let originalManifestData = shouldWriteManifest
            ? try existingSafeManifestData(at: manifestURL)
            : nil
        do {
            if let serializedData {
                for url in targetURLs {
                    try writeLibraryFoldersData(serializedData, to: url)
                }
                let ownedRegistrationsForReadback: [OwnedRegistration]
                if reconciliationScope == .authoritativeStorageInventory {
                    ownedRegistrationsForReadback = Array(
                        nextOwnedByPath.values
                    )
                } else {
                    // Unrepresented entries remain byte-for-byte owned state,
                    // but this partial authorization cannot inspect or repair
                    // them. Verify only registrations covered by this request.
                    ownedRegistrationsForReadback = nextOwnedByPath.compactMap {
                        path, ownership in
                        activePaths.contains(path) ? ownership : nil
                    }
                }
                try verifyLibraryFolders(
                    at: targetURLs,
                    satisfies: Array(activeByPath.values),
                    ownedRegistrations: ownedRegistrationsForReadback,
                    excludes: removedPaths,
                    prefix: prefix
                )
            }
            if shouldWriteManifest {
                try writeRegistrationManifest(nextManifest, to: manifestURL)
            }
        } catch {
            let rollbackFailures = restoreFiles(originals) +
                (shouldWriteManifest
                    ? restoreFile(
                        at: manifestURL,
                        originalData: originalManifestData
                    )
                    : [])
            if rollbackFailures.isEmpty,
               let bridgeError = error as? SteamLibraryDriveBridgeError {
                throw bridgeError
            }
            let rollbackDetail = rollbackFailures.isEmpty
                ? ""
                : "; rollback failures: \(rollbackFailures.joined(separator: " | "))"
            throw SteamLibraryDriveBridgeError.libraryFoldersWriteFailed(
                authoritativeURL,
                forgePlayTechnicalErrorSummary(error) + rollbackDetail
            )
        }
    }

    nonisolated static func mappedWindowsLibraryPath(
        for libraryRoot: URL,
        prefix: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let normalizedLibraryPath = libraryRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        for letter in libraryDriveLetters {
            let driveLink = dosdevices.appending(path: "\(letter):")
            guard let target = try? fileManager.destinationOfSymbolicLink(atPath: driveLink.path) else {
                continue
            }
            let targetURL = target.hasPrefix("/")
                ? URL(fileURLWithPath: target, isDirectory: true)
                : driveLink.deletingLastPathComponent().appending(path: target, directoryHint: .isDirectory)
            let resolvedTarget = targetURL.resolvingSymlinksInPath().standardizedFileURL
            if let directPath = windowsLibraryPath(
                driveLetter: letter,
                driveRoot: resolvedTarget,
                libraryRoot: URL(
                    fileURLWithPath: normalizedLibraryPath,
                    isDirectory: true
                )
            ) {
                return directPath
            }
            let libraryLink = resolvedTarget.appending(path: bridgeLibraryDirectoryName)
            guard let libraryTarget = try? fileManager.destinationOfSymbolicLink(atPath: libraryLink.path) else {
                continue
            }
            let libraryTargetURL = libraryTarget.hasPrefix("/")
                ? URL(fileURLWithPath: libraryTarget, isDirectory: true)
                : resolvedTarget.appending(path: libraryTarget, directoryHint: .isDirectory)
            if libraryTargetURL.resolvingSymlinksInPath().standardizedFileURL.path == normalizedLibraryPath {
                return "\(letter.uppercased()):\\\(bridgeLibraryDirectoryName)"
            }
        }
        return nil
    }

    private nonisolated static func windowsLibraryPath(
        driveLetter: String,
        driveRoot: URL,
        libraryRoot: URL
    ) -> String? {
        guard let relativePath = relativeWindowsLibraryPath(
            driveRoot: driveRoot,
            libraryRoot: libraryRoot
        ) else {
            return nil
        }
        guard !relativePath.isEmpty else {
            return "\(driveLetter.uppercased()):\\"
        }
        return "\(driveLetter.uppercased()):\\\(relativePath)"
    }

    private nonisolated static func relativeWindowsLibraryPath(
        driveRoot: URL,
        libraryRoot: URL
    ) -> String? {
        let resolvedDriveRoot = driveRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedLibraryRoot = libraryRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let driveComponents = URL(
            fileURLWithPath: resolvedDriveRoot,
            isDirectory: true
        ).pathComponents
        let libraryComponents = URL(
            fileURLWithPath: resolvedLibraryRoot,
            isDirectory: true
        ).pathComponents
        guard libraryComponents.count >= driveComponents.count,
              Array(libraryComponents.prefix(driveComponents.count)) ==
                driveComponents else {
            return nil
        }
        return libraryComponents
            .dropFirst(driveComponents.count)
            .joined(separator: "\\")
    }

    private func mergedLibraryFoldersDocument(
        from urls: [URL]
    ) throws -> [String: VDFValue] {
        var documents: [[String: VDFValue]] = []
        for url in urls where fileManager.fileExists(atPath: url.path) {
            documents.append(try loadLibraryFoldersDocument(at: url))
        }
        guard var document = documents.first else {
            return defaultLibraryFoldersDocument()
        }
        guard var mergedFolders = document["libraryfolders"]?.objectValue else {
            throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                urls.first ?? URL(fileURLWithPath: "libraryfolders.vdf"),
                "missing libraryfolders object"
            )
        }
        var registeredKeysByPath: [String: String] = [:]
        for (key, value) in mergedFolders {
            guard let path = value.objectValue?["path"]?.stringValue else {
                continue
            }
            registeredKeysByPath[normalizedWindowsPath(path)] = key
        }

        for additionalDocument in documents.dropFirst() {
            guard let additionalFolders =
                    additionalDocument["libraryfolders"]?.objectValue else {
                throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                    urls.first ?? URL(fileURLWithPath: "libraryfolders.vdf"),
                    "compatibility copy is missing the libraryfolders object"
                )
            }
            for (key, value) in additionalFolders {
                if let path = value.objectValue?["path"]?.stringValue {
                    let normalizedPath = normalizedWindowsPath(path)
                    if let existingKey = registeredKeysByPath[normalizedPath],
                       let existingValue = mergedFolders[existingKey] {
                        mergedFolders[existingKey] = mergedLibraryFolderEntry(
                            preferred: existingValue,
                            supplement: value
                        )
                        continue
                    }
                    let nextKey = nextLibraryIndex(in: mergedFolders)
                    mergedFolders[nextKey] = value
                    registeredKeysByPath[normalizedPath] = nextKey
                } else if mergedFolders[key] == nil {
                    mergedFolders[key] = value
                }
            }
        }
        document["libraryfolders"] = .object(mergedFolders)
        return document
    }

    private func mergedLibraryFolderEntry(
        preferred: VDFValue,
        supplement: VDFValue
    ) -> VDFValue {
        guard var merged = preferred.objectValue,
              let supplementaryObject = supplement.objectValue else {
            return preferred
        }
        for (key, value) in supplementaryObject where merged[key] == nil {
            merged[key] = value
        }
        if let preferredApps = preferred.objectValue?["apps"]?.objectValue,
           let supplementaryApps = supplementaryObject["apps"]?.objectValue {
            var mergedApps = supplementaryApps
            for (appIdentifier, value) in preferredApps {
                mergedApps[appIdentifier] = value
            }
            merged["apps"] = .object(mergedApps)
        }
        return .object(merged)
    }

    private func loadLibraryFoldersDocument(
        at url: URL
    ) throws -> [String: VDFValue] {
        do {
            guard let text = try SteamVDFFileReader.readText(
                url,
                maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes
            ) else {
                throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                    url,
                    "file is unsafe or too large"
                )
            }
            let document = try VDFParser().parse(text)
            guard document["libraryfolders"]?.objectValue != nil else {
                throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                    url,
                    "missing libraryfolders object"
                )
            }
            return document
        } catch let error as SteamLibraryDriveBridgeError {
            throw error
        } catch {
            throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                url,
                forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    private func defaultLibraryFoldersDocument() -> [String: VDFValue] {
        let defaultPath = "C:\\Program Files (x86)\\Steam"
        return [
            "libraryfolders": .object([
                "0": .object([
                    "path": .string(defaultPath),
                    "label": .string(""),
                    "contentid": .string(stableContentID(for: defaultPath)),
                    "totalsize": .string("0"),
                    "update_clean_bytes_tally": .string("0"),
                    "time_last_update_verified": .string("0"),
                    "apps": .object([:])
                ])
            ])
        ]
    }

    private func libraryFolderEntry(
        for mapping: SteamLibraryDriveMapping,
        ownership: OwnedRegistration
    ) -> VDFValue {
        return .object([
            "path": .string(mapping.windowsLibraryPath),
            "label": .string(""),
            "contentid": .string(ownership.contentID),
            "totalsize": .string("0"),
            "update_clean_bytes_tally": .string("0"),
            "time_last_update_verified": .string("0"),
            "apps": .object([:])
        ])
    }

    /// Updates only the identity field ForgePlay owns. Steam may have
    /// canonicalized the path or populated size, verification, and app
    /// metadata after the original registration; those values must survive a
    /// legacy ownership migration.
    private func libraryFolderEntry(
        updating existingEntry: VDFValue,
        ownership: OwnedRegistration
    ) -> VDFValue {
        guard var object = existingEntry.objectValue else {
            return existingEntry
        }
        object["contentid"] = .string(ownership.contentID)
        return .object(object)
    }

    private func ownedRegistration(
        for mapping: SteamLibraryDriveMapping,
        contentID: String
    ) -> OwnedRegistration {
        let canonicalDriveRoot = mapping.macDriveRootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let canonicalLibrary = mapping.macLibraryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return OwnedRegistration(
            normalizedWindowsPath: normalizedWindowsPath(
                mapping.windowsLibraryPath
            ),
            driveRootStorageIdentity: storageIdentity(
                for: mapping.macDriveRootURL
            ),
            canonicalDriveRootPath: canonicalDriveRoot,
            canonicalLibraryPath: canonicalLibrary,
            contentID: contentID
        )
    }

    /// Steam binds a configured library entry to the `contentid` stored in
    /// that library root's own `libraryfolder.vdf`. Supplying a different ID
    /// leaves the path visible as a drive but makes Steam reject it as not
    /// mounted, so ForgePlay must read and preserve Steam's identity rather
    /// than derive one from the macOS path.
    private func steamLibraryContentID(
        for mapping: SteamLibraryDriveMapping
    ) throws -> String {
        try steamLibraryContentID(at: mapping.macLibraryURL)
    }

    private func steamLibraryContentID(at libraryURL: URL) throws -> String {
        let identityURL = libraryURL.appending(
            path: "libraryfolder.vdf",
            directoryHint: .notDirectory
        )
        do {
            guard let text = try SteamVDFFileReader.readText(
                identityURL,
                maxBytes: 16 * 1_024
            ) else {
                throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                    identityURL,
                    "the existing Steam library identity marker is missing, unsafe, or too large"
                )
            }
            let document = try VDFParser().parse(text)
            guard let identity = document["libraryfolder"]?.objectValue,
                  let rawContentID = identity["contentid"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  let numericContentID = UInt64(rawContentID),
                  numericContentID > 0 else {
                throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                    identityURL,
                    "the existing Steam library identity marker has no valid nonzero contentid"
                )
            }
            return String(numericContentID)
        } catch let error as SteamLibraryDriveBridgeError {
            throw error
        } catch {
            throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                identityURL,
                forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    private func registrationTarget(
        _ lhs: OwnedRegistration,
        matches rhs: OwnedRegistration
    ) -> Bool {
        // A removable volume can be remounted at a different host path while
        // retaining the same volume UUID and Windows drive assignment. The
        // stable storage identity plus normalized Windows path identifies the
        // same registration target; canonical host paths are readback
        // metadata that must be refreshed after a remount, not ownership.
        lhs.normalizedWindowsPath == rhs.normalizedWindowsPath &&
            lhs.driveRootStorageIdentity == rhs.driveRootStorageIdentity
    }

    private func canonicalLibraryPath(
        for mapping: SteamLibraryDriveMapping
    ) -> String {
        mapping.macLibraryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private func canonicalExistingLibraryPath(
        fromWindowsPath path: String,
        prefix: URL
    ) -> String? {
        guard let libraryURL = Self.validatedMacURL(
            fromSteamLibraryPath: path,
            prefix: prefix
        ),
        FileSystemItemPolicy.isNonSymlinkDirectory(
            libraryURL,
            fileManager: fileManager
        ) else {
            return nil
        }
        return libraryURL.resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private func registrationEntry(
        _ entry: VDFValue,
        matches ownership: OwnedRegistration
    ) -> Bool {
        guard let object = entry.objectValue,
              let path = object["path"]?.stringValue,
              let contentID = object["contentid"]?.stringValue else {
            return false
        }
        return normalizedWindowsPath(path) == ownership.normalizedWindowsPath &&
            contentID == ownership.contentID
    }

    private func registrationOwnershipMatchesEveryExistingCopy(
        _ ownership: OwnedRegistration,
        at urls: [URL]
    ) throws -> Bool {
        var foundRegistration = false
        for url in urls where fileManager.fileExists(atPath: url.path) {
            let document = try loadLibraryFoldersDocument(at: url)
            guard let folders = document["libraryfolders"]?.objectValue else {
                throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                    url,
                    "missing libraryfolders object"
                )
            }
            for entry in folders.values {
                guard let path = entry.objectValue?["path"]?.stringValue,
                      normalizedWindowsPath(path) ==
                        ownership.normalizedWindowsPath else {
                    continue
                }
                foundRegistration = true
                guard registrationEntry(entry, matches: ownership) else {
                    return false
                }
            }
        }
        return foundRegistration
    }

    private func nextLibraryIndex(in folders: [String: VDFValue]) -> String {
        var index = 0
        while folders[String(index)] != nil {
            index += 1
        }
        return String(index)
    }

    private func normalizedWindowsPath(_ path: String) -> String {
        var normalized = path.replacingOccurrences(of: "/", with: "\\")
        if normalized.count == 2, normalized.hasSuffix(":") {
            normalized.append("\\")
        }
        while normalized.count > 3, normalized.hasSuffix("\\") {
            normalized.removeLast()
        }
        return normalized.lowercased()
    }

    private func stableContentID(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash == 0 ? 1 : hash)
    }

    private func existingSafeLibraryFoldersData(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(
                url,
                fileManager: fileManager
            )
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= SteamVDFFileReader.maxLibraryFoldersBytes else {
                throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                    url,
                    "file is too large"
                )
            }
            return try Data(contentsOf: url)
        } catch let error as SteamLibraryDriveBridgeError {
            throw error
        } catch {
            throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                url,
                forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    private func writeLibraryFoldersData(_ data: Data, to url: URL) throws {
        guard data.count <= SteamVDFFileReader.maxLibraryFoldersBytes else {
            throw SteamLibraryDriveBridgeError.libraryFoldersWriteFailed(
                url,
                "serialized libraryfolders.vdf exceeds the size limit"
            )
        }
        let parent = url.deletingLastPathComponent()
        guard FileSystemItemPolicy.isNonSymlinkDirectory(parent, fileManager: fileManager) else {
            throw SteamLibraryDriveBridgeError.libraryFoldersUnavailable(parent)
        }
        if fileManager.fileExists(atPath: url.path) {
            do {
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(
                    url,
                    fileManager: fileManager
                )
            } catch {
                throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                    url,
                    forgePlayTechnicalErrorSummary(error)
                )
            }
        }
        do {
            try data.write(to: url, options: .atomic)
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(
                url,
                fileManager: fileManager
            )
        } catch let error as SteamLibraryDriveBridgeError {
            throw error
        } catch {
            throw SteamLibraryDriveBridgeError.libraryFoldersWriteFailed(
                url,
                forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    private func verifyLibraryFolders(
        at urls: [URL],
        satisfies mappings: [SteamLibraryDriveMapping],
        ownedRegistrations: [OwnedRegistration],
        excludes removedPaths: Set<String>,
        prefix: URL
    ) throws {
        for url in urls {
            let document = try loadLibraryFoldersDocument(at: url)
            guard let folders = document["libraryfolders"]?.objectValue else {
                throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                    url,
                    "written file is missing the libraryfolders object"
                )
            }
            let writtenPaths = Set(folders.values.compactMap { value in
                value.objectValue?["path"]?.stringValue.map(normalizedWindowsPath)
            })
            let writtenCanonicalLibraryPaths = Set(
                folders.values.compactMap { value in
                    value.objectValue?["path"]?.stringValue.flatMap {
                        canonicalExistingLibraryPath(
                            fromWindowsPath: $0,
                            prefix: prefix
                        )
                    }
                }
            )
            let unsatisfied = mappings.compactMap { mapping -> String? in
                let desiredPath = normalizedWindowsPath(
                    mapping.windowsLibraryPath
                )
                guard !writtenPaths.contains(desiredPath),
                      !writtenCanonicalLibraryPaths.contains(
                          canonicalLibraryPath(for: mapping)
                      ) else {
                    return nil
                }
                return desiredPath
            }
            let stale = removedPaths.intersection(writtenPaths)
            let entriesByPath = Dictionary(
                folders.values.compactMap { value -> (String, VDFValue)? in
                    guard let path = value.objectValue?["path"]?.stringValue
                    else { return nil }
                    return (normalizedWindowsPath(path), value)
                },
                uniquingKeysWith: { existing, _ in existing }
            )
            let identityMismatches = ownedRegistrations.compactMap {
                ownership -> String? in
                guard let entry = entriesByPath[
                    ownership.normalizedWindowsPath
                ], registrationEntry(entry, matches: ownership) else {
                    return ownership.normalizedWindowsPath
                }
                return nil
            }
            guard unsatisfied.isEmpty,
                  stale.isEmpty,
                  identityMismatches.isEmpty else {
                throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                    url,
                    "readback mismatch; unsatisfied=\(unsatisfied.sorted()), stale=\(stale.sorted()), identity_mismatches=\(identityMismatches.sorted())"
                )
            }
        }
    }

    private func loadRegistrationManifest(
        at url: URL
    ) throws -> RegistrationManifest {
        guard fileManager.fileExists(atPath: url.path) else {
            return .empty
        }
        do {
            guard let data = try existingSafeManifestData(at: url) else {
                return .empty
            }
            let decoder = JSONDecoder()
            let version = try decoder.decode(
                ManifestVersion.self,
                from: data
            ).version
            if version == 1 {
                let legacyManifest = try decoder.decode(
                    LegacyRegistrationManifest.self,
                    from: data
                )
                guard legacyManifest.version == 1,
                      legacyManifest.ownedWindowsPaths.allSatisfy({
                          !$0.trimmingCharacters(
                              in: .whitespacesAndNewlines
                          ).isEmpty
                      }) else {
                    throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                        url,
                        "invalid legacy ForgePlay registration manifest"
                    )
                }
                // Schema 1 tracked paths only. A path can later be reused by
                // Steam or the user, so it is not sufficient proof of
                // ForgePlay ownership and is deliberately migrated as
                // unowned.
                return .empty
            }
            let manifest = try decoder.decode(
                RegistrationManifest.self,
                from: data
            )
            let uniquePaths = Set(
                manifest.ownedRegistrations.map(\.normalizedWindowsPath)
            )
            guard manifest.version == 2 ||
                    manifest.version == RegistrationManifest.currentVersion,
                  uniquePaths.count == manifest.ownedRegistrations.count,
                  manifest.ownedRegistrations.allSatisfy({
                      isValidOwnedRegistration(
                          $0,
                          manifestVersion: manifest.version
                      )
                  }) else {
                throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                    url,
                    "invalid ForgePlay registration manifest"
                )
            }
            return RegistrationManifest(
                version: manifest.version,
                ownedRegistrations: manifest.ownedRegistrations.sorted {
                    $0.normalizedWindowsPath < $1.normalizedWindowsPath
                }
            )
        } catch let error as SteamLibraryDriveBridgeError {
            throw error
        } catch {
            throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                url,
                forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    private func isValidOwnedRegistration(
        _ registration: OwnedRegistration,
        manifestVersion: Int
    ) -> Bool {
        guard !registration.normalizedWindowsPath.isEmpty,
              registration.normalizedWindowsPath ==
                normalizedWindowsPath(registration.normalizedWindowsPath),
              !registration.driveRootStorageIdentity.isEmpty,
              !registration.canonicalDriveRootPath.isEmpty,
              !registration.canonicalLibraryPath.isEmpty,
              registration.canonicalDriveRootPath.hasPrefix("/"),
              registration.canonicalLibraryPath.hasPrefix("/"),
              URL(
                  fileURLWithPath: registration.canonicalDriveRootPath,
                  isDirectory: true
              ).standardizedFileURL.path == registration.canonicalDriveRootPath,
              URL(
                  fileURLWithPath: registration.canonicalLibraryPath,
                  isDirectory: true
              ).standardizedFileURL.path == registration.canonicalLibraryPath,
              isValidSteamLibraryContentID(registration.contentID),
              manifestVersion != 2 ||
                registration.contentID == stableContentID(
                    for: registration.canonicalLibraryPath
                ) else {
            return false
        }
        let driveRootPrefix = registration.canonicalDriveRootPath == "/"
            ? "/"
            : registration.canonicalDriveRootPath + "/"
        return registration.canonicalLibraryPath ==
            registration.canonicalDriveRootPath ||
            registration.canonicalLibraryPath.hasPrefix(driveRootPrefix)
    }

    private func isValidSteamLibraryContentID(_ contentID: String) -> Bool {
        guard let value = UInt64(contentID), value > 0 else { return false }
        return contentID == String(value)
    }

    private func existingSafeManifestData(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(
                url,
                fileManager: fileManager
            )
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 16 * 1024 else {
                throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                    url,
                    "ForgePlay registration manifest is too large"
                )
            }
            return try Data(contentsOf: url)
        } catch let error as SteamLibraryDriveBridgeError {
            throw error
        } catch {
            throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                url,
                forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    private func writeRegistrationManifest(
        _ manifest: RegistrationManifest,
        to url: URL
    ) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(manifest)
            guard data.count <= 16 * 1024 else {
                throw SteamLibraryDriveBridgeError.libraryFoldersWriteFailed(
                    url,
                    "ForgePlay registration manifest exceeds the size limit"
                )
            }
            try data.write(to: url, options: .atomic)
            let verified = try loadRegistrationManifest(at: url)
            guard verified == manifest else {
                throw SteamLibraryDriveBridgeError.libraryFoldersInvalid(
                    url,
                    "ForgePlay registration manifest readback mismatch"
                )
            }
        } catch let error as SteamLibraryDriveBridgeError {
            throw error
        } catch {
            throw SteamLibraryDriveBridgeError.libraryFoldersWriteFailed(
                url,
                forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    private func restoreFiles(_ originals: [(URL, Data?)]) -> [String] {
        originals.flatMap { original in
            restoreFile(at: original.0, originalData: original.1)
        }
    }

    private func restoreFile(at url: URL, originalData: Data?) -> [String] {
        do {
            if let originalData {
                try originalData.write(to: url, options: .atomic)
            } else if fileManager.fileExists(atPath: url.path) {
                try FileSystemItemPolicy.requireRegularNonSymlinkFile(
                    url,
                    fileManager: fileManager
                )
                try fileManager.removeItem(at: url)
            }
            return []
        } catch {
            return ["\(url.path): \(forgePlayTechnicalErrorSummary(error))"]
        }
    }

    private func normalizedSelectedDriveRoots(_ roots: [URL]) -> [URL] {
        var seen = Set<String>()
        var output: [URL] = []
        for root in roots {
            let normalized = root.standardizedFileURL
            if seen.insert(storageIdentity(for: normalized)).inserted {
                output.append(normalized)
            }
        }
        return output.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func normalizedDriveSources(
        _ sources: [SteamLibraryDriveSource]
    ) -> [NormalizedDriveSource] {
        var seen = Set<String>()
        var output: [NormalizedDriveSource] = []
        for source in sources {
            let authorizedRoot = source.authorizedRootURL.standardizedFileURL
            let libraryRoot = source.libraryURL.standardizedFileURL
            let identity = [
                storageIdentity(for: authorizedRoot),
                libraryRoot.resolvingSymlinksInPath().standardizedFileURL.path
            ].joined(separator: "|")
            if seen.insert(identity).inserted {
                output.append(NormalizedDriveSource(
                    authorizedRootURL: authorizedRoot,
                    libraryURL: libraryRoot
                ))
            }
        }
        return output.sorted {
            let rootOrder = $0.authorizedRootURL.path.localizedStandardCompare(
                $1.authorizedRootURL.path
            )
            if rootOrder != .orderedSame {
                return rootOrder == .orderedAscending
            }
            return $0.libraryURL.path.localizedStandardCompare($1.libraryURL.path) ==
                .orderedAscending
        }
    }

    private func validateAuthorizedDriveRootsBeforeMutation(
        _ roots: [URL]
    ) throws {
        for root in roots {
            guard FileSystemItemPolicy.isNonSymlinkDirectory(
                root,
                fileManager: fileManager
            ) else {
                throw SteamLibraryDriveBridgeError.libraryRootUnavailable(root)
            }
        }
    }

    private func validateDriveSourcesBeforeMutation(
        _ sources: [NormalizedDriveSource]
    ) throws {
        for source in sources {
            guard FileSystemItemPolicy.isNonSymlinkDirectory(
                source.authorizedRootURL,
                fileManager: fileManager
            ) else {
                throw SteamLibraryDriveBridgeError.libraryRootUnavailable(
                    source.authorizedRootURL
                )
            }
            guard FileSystemItemPolicy.isNonSymlinkDirectory(
                source.libraryURL,
                fileManager: fileManager
            ),
            Self.relativeWindowsLibraryPath(
                driveRoot: source.authorizedRootURL,
                libraryRoot: source.libraryURL
            ) != nil else {
                throw SteamLibraryDriveBridgeError.libraryRootUnavailable(
                    source.libraryURL
                )
            }
        }
    }

    /// Registration is optional while Steam is creating a library. Missing,
    /// partial, zero-content-ID, oversized, or symlinked identity files are
    /// left entirely to Steam and do not block the already-authorized drive
    /// or its process grant. The strict existing-library entry points still
    /// surface these states as errors before any mutation.
    private func isSteamLibraryRegistrationReady(at libraryURL: URL) -> Bool {
        let identityURL = libraryURL.appending(
            path: "libraryfolder.vdf",
            directoryHint: .notDirectory
        )
        guard fileSystemItemExists(at: identityURL) else { return false }
        return (try? steamLibraryContentID(at: libraryURL)) != nil
    }

    private func windowsLibraryPath(
        driveLetter: String,
        authorizedRoot: URL,
        libraryRoot: URL
    ) throws -> String {
        guard let path = Self.windowsLibraryPath(
            driveLetter: driveLetter,
            driveRoot: authorizedRoot,
            libraryRoot: libraryRoot
        ) else {
            throw SteamLibraryDriveBridgeError.libraryRootUnavailable(libraryRoot)
        }
        return path
    }

    private func driveLetter(
        for libraryRoot: URL,
        dosdevices: URL,
        bridgeDirectory: URL,
        usedLetters: inout Set<String>
    ) throws -> String? {
        for letter in Self.libraryDriveLetters where !usedLetters.contains(letter) {
            let bridgeRoot = bridgeDirectory.appending(path: letter, directoryHint: .isDirectory)
            guard let assignment = try readAssignment(at: bridgeRoot),
                  assignmentMatches(assignment, libraryRoot: libraryRoot) else {
                continue
            }
            let link = dosdevices.appending(path: "\(letter):")
            let deviceLink = dosdevices.appending(path: "\(letter)::")
            if fileSystemItemExists(at: deviceLink) {
                try abandonDriveReservation(at: bridgeRoot)
                continue
            }
            if let existingTarget = try? fileManager.destinationOfSymbolicLink(
                atPath: link.path
            ) {
                let resolvedTarget = resolvedSymlinkTarget(
                    existingTarget,
                    relativeTo: dosdevices
                )
                let recordedTarget = URL(
                    fileURLWithPath: assignment.lastKnownPath,
                    isDirectory: true
                ).resolvingSymlinksInPath().standardizedFileURL.path
                let existingURL = URL(
                    fileURLWithPath: resolvedTarget,
                    isDirectory: true
                )
                let canReuse =
                    directDriveTarget(resolvedTarget, contains: libraryRoot) ||
                    resolvedTarget == bridgeRoot.standardizedFileURL.path ||
                    bridgeTargetsLibrary(
                        existingURL,
                        libraryRoot: libraryRoot,
                        bridgeDirectory: bridgeDirectory
                    ) ||
                    (
                        assignment.driveLinkOwnership == .forgePlay &&
                            resolvedTarget == recordedTarget
                    )
                guard canReuse else {
                    try abandonDriveReservation(at: bridgeRoot)
                    continue
                }
                usedLetters.insert(letter)
                return letter
            }
            if fileSystemItemExists(at: link) {
                try abandonDriveReservation(at: bridgeRoot)
                continue
            }
            usedLetters.insert(letter)
            return letter
        }
        for letter in Self.libraryDriveLetters where !usedLetters.contains(letter) {
            let link = dosdevices.appending(path: "\(letter):")
            let deviceLink = dosdevices.appending(path: "\(letter)::")
            let bridgeRoot = bridgeDirectory.appending(path: letter, directoryHint: .isDirectory)
            guard !fileSystemItemExists(at: deviceLink) else {
                continue
            }
            if let existingTarget = try? fileManager.destinationOfSymbolicLink(
                atPath: link.path
            ) {
                let resolvedTarget = resolvedSymlinkTarget(
                    existingTarget,
                    relativeTo: link.deletingLastPathComponent()
                )
                if directDriveTarget(resolvedTarget, contains: libraryRoot) ||
                    bridgeTargetsLibrary(
                        URL(fileURLWithPath: resolvedTarget, isDirectory: true),
                        libraryRoot: libraryRoot,
                        bridgeDirectory: bridgeDirectory
                    ) {
                    usedLetters.insert(letter)
                    return letter
                }
                continue
            }
            guard !fileSystemItemExists(at: link) else {
                continue
            }
            if !fileManager.fileExists(atPath: bridgeRoot.path) {
                usedLetters.insert(letter)
                return letter
            }
        }
        return nil
    }

    private func fileSystemItemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) ||
            (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func storageIdentity(for libraryRoot: URL) -> String {
        if let storageIdentityProvider {
            return storageIdentityProvider(libraryRoot.standardizedFileURL)
        }
        let resolvedRoot = libraryRoot.resolvingSymlinksInPath().standardizedFileURL
        guard let values = try? resolvedRoot.resourceValues(
            forKeys: [.volumeUUIDStringKey, .volumeURLKey]
        ),
        let volumeUUID = values.volumeUUIDString?.trimmingCharacters(in: .whitespacesAndNewlines),
        !volumeUUID.isEmpty,
        let volumeURL = values.volume?.resolvingSymlinksInPath().standardizedFileURL else {
            return "path:\(resolvedRoot.path)"
        }

        let volumePath = volumeURL.path == "/" ? "/" : volumeURL.path + "/"
        let relativePath: String
        if resolvedRoot.path == volumeURL.path {
            relativePath = ""
        } else if resolvedRoot.path.hasPrefix(volumePath) {
            relativePath = String(resolvedRoot.path.dropFirst(volumePath.count))
        } else {
            return "path:\(resolvedRoot.path)"
        }
        return "volume-uuid:\(volumeUUID.lowercased()):\(relativePath)"
    }

    private func assignmentMatches(_ assignment: DriveAssignment, libraryRoot: URL) -> Bool {
        assignment.storageIdentity == storageIdentity(for: libraryRoot) ||
            URL(fileURLWithPath: assignment.lastKnownPath, isDirectory: true)
                .standardizedFileURL.path == libraryRoot.standardizedFileURL.path
    }

    private func assignmentURL(in bridgeRoot: URL) -> URL {
        bridgeRoot.appending(path: Self.assignmentFileName)
    }

    private func previousManagedDirectTarget(
        at bridgeRoot: URL,
        for libraryRoot: URL
    ) throws -> URL? {
        guard let assignment = try readAssignment(at: bridgeRoot),
              assignment.driveLinkOwnership == .forgePlay,
              assignmentMatches(assignment, libraryRoot: libraryRoot) else {
            return nil
        }
        let libraryLink = bridgeRoot.appending(path: Self.bridgeLibraryDirectoryName)
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: libraryLink.path) else {
            return nil
        }
        let resolvedTarget = resolvedSymlinkTarget(target, relativeTo: bridgeRoot)
        let recordedTarget = URL(
            fileURLWithPath: assignment.lastKnownPath,
            isDirectory: true
        ).resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedTarget == recordedTarget else { return nil }
        return URL(fileURLWithPath: resolvedTarget, isDirectory: true)
    }

    private func reservedOnlyStorageIdentities(
        in bridgeDirectory: URL
    ) throws -> Set<String> {
        guard fileManager.fileExists(atPath: bridgeDirectory.path) else {
            return []
        }
        guard FileSystemItemPolicy.isNonSymlinkDirectory(
            bridgeDirectory,
            fileManager: fileManager
        ) else {
            throw SteamLibraryDriveBridgeError.bridgeDirectoryUnavailable(
                bridgeDirectory
            )
        }
        var identities = Set<String>()
        for letter in Self.libraryDriveLetters {
            let bridgeRoot = bridgeDirectory.appending(
                path: letter,
                directoryHint: .isDirectory
            )
            guard fileManager.fileExists(atPath: bridgeRoot.path),
                  let assignment = try readAssignment(at: bridgeRoot),
                  assignment.isReservedOnly == true else {
                continue
            }
            identities.insert(assignment.storageIdentity)
        }
        return identities
    }

    private func readAssignment(at bridgeRoot: URL) throws -> DriveAssignment? {
        let url = assignmentURL(in: bridgeRoot)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(url, fileManager: fileManager)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 16 * 1024 else {
                throw SteamLibraryDriveBridgeError.bridgeDirectoryUnavailable(bridgeRoot)
            }
            let assignment = try JSONDecoder().decode(DriveAssignment.self, from: Data(contentsOf: url))
            guard DriveAssignment.supportedVersions.contains(assignment.version),
                  !assignment.storageIdentity.isEmpty,
                  !assignment.lastKnownPath.isEmpty,
                  assignment.version == 1 ||
                    (
                        assignment.version == 2 &&
                            assignment.driveLinkOwnership != nil
                    ) ||
                    (
                        assignment.version == DriveAssignment.currentVersion &&
                            assignment.driveLinkOwnership != nil &&
                            assignment.isReservedOnly != nil
                    ) else {
                throw SteamLibraryDriveBridgeError.bridgeDirectoryUnavailable(bridgeRoot)
            }
            return DriveAssignment(
                version: assignment.version,
                storageIdentity: assignment.storageIdentity,
                lastKnownPath: assignment.lastKnownPath,
                driveLinkOwnership: assignment.version >= 2
                    ? assignment.driveLinkOwnership
                    : nil,
                isReservedOnly:
                    assignment.version == DriveAssignment.currentVersion
                        ? assignment.isReservedOnly
                        : false
            )
        } catch let error as SteamLibraryDriveBridgeError {
            throw error
        } catch {
            throw SteamLibraryDriveBridgeError.bridgeDirectoryUnavailable(bridgeRoot)
        }
    }

    private func writeAssignment(
        for libraryRoot: URL,
        at bridgeRoot: URL,
        driveLinkOwnership: DriveLinkOwnership,
        isReservedOnly: Bool
    ) throws {
        let assignment = DriveAssignment(
            version: DriveAssignment.currentVersion,
            storageIdentity: storageIdentity(for: libraryRoot),
            lastKnownPath: libraryRoot.standardizedFileURL.path,
            driveLinkOwnership: driveLinkOwnership,
            isReservedOnly: isReservedOnly
        )
        try writeAssignment(assignment, at: bridgeRoot)
    }

    private func writeAssignment(
        _ assignment: DriveAssignment,
        at bridgeRoot: URL
    ) throws {
        do {
            try JSONEncoder().encode(assignment).write(
                to: assignmentURL(in: bridgeRoot),
                options: .atomic
            )
        } catch {
            throw SteamLibraryDriveBridgeError.bridgeDirectoryUnavailable(bridgeRoot)
        }
    }

    private func abandonDriveReservation(at bridgeRoot: URL) throws {
        guard fileManager.fileExists(atPath: bridgeRoot.path) else { return }
        guard FileSystemItemPolicy.isNonSymlinkDirectory(
            bridgeRoot,
            fileManager: fileManager
        ) else {
            throw SteamLibraryDriveBridgeError.bridgeDirectoryUnavailable(bridgeRoot)
        }
        do {
            try fileManager.removeItem(at: bridgeRoot)
        } catch {
            throw SteamLibraryDriveBridgeError.bridgeDirectoryUnavailable(bridgeRoot)
        }
    }

    private func removeOrphanedBridgeReservations(
        dosdevices: URL,
        bridgeDirectory: URL,
        requestedRoots: [URL]
    ) throws {
        for letter in Self.libraryDriveLetters {
            let bridgeRoot = bridgeDirectory.appending(path: letter, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: bridgeRoot.path) else { continue }
            guard FileSystemItemPolicy.isNonSymlinkDirectory(bridgeRoot, fileManager: fileManager) else {
                throw SteamLibraryDriveBridgeError.bridgeDirectoryUnavailable(bridgeRoot)
            }
            let assignment = try readAssignment(at: bridgeRoot)
            let isRequested = requestedRoots.contains { root in
                if let assignment, assignmentMatches(assignment, libraryRoot: root) {
                    return true
                }
                return bridgeTargetsLibrary(
                    bridgeRoot,
                    libraryRoot: root,
                    bridgeDirectory: bridgeDirectory
                )
            }
            if !isRequested {
                try removeManagedBridge(
                    letter: letter,
                    dosdevices: dosdevices,
                    bridgeDirectory: bridgeDirectory,
                    removesReservation: true
                )
            }
        }
    }

    private func resolvedSymlinkTarget(_ target: String, relativeTo base: URL) -> String {
        let targetURL: URL
        if target.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: target)
        } else {
            targetURL = base.appending(path: target)
        }
        return targetURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func removeInactiveManagedBridges(
        dosdevices: URL,
        bridgeDirectory: URL,
        activeDriveLetters: Set<String>,
        reservedDriveLetters: Set<String>
    ) throws {
        for letter in Self.libraryDriveLetters where !activeDriveLetters.contains(letter) {
            let bridgeRoot = bridgeDirectory.appending(path: letter, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: bridgeRoot.path) else { continue }
            guard FileSystemItemPolicy.isNonSymlinkDirectory(bridgeRoot, fileManager: fileManager) else {
                throw SteamLibraryDriveBridgeError.bridgeDirectoryUnavailable(bridgeRoot)
            }
            try removeManagedBridge(
                letter: letter,
                dosdevices: dosdevices,
                bridgeDirectory: bridgeDirectory,
                removesReservation: !reservedDriveLetters.contains(letter)
            )
        }
    }

    private func removeManagedBridge(
        letter: String,
        dosdevices: URL,
        bridgeDirectory: URL,
        removesReservation: Bool
    ) throws {
        let bridgeRoot = bridgeDirectory.appending(path: letter, directoryHint: .isDirectory)
        let driveLink = dosdevices.appending(path: "\(letter):")
        let assignment = try readAssignment(at: bridgeRoot)
        if let target = try? fileManager.destinationOfSymbolicLink(atPath: driveLink.path) {
            let resolvedDriveTarget = resolvedSymlinkTarget(target, relativeTo: dosdevices)
            let recordedDirectTarget = assignment.map {
                URL(
                    fileURLWithPath: $0.lastKnownPath,
                    isDirectory: true
                ).resolvingSymlinksInPath().standardizedFileURL.path
            }
            let isOwnedDirectTarget =
                assignment?.driveLinkOwnership == .forgePlay &&
                recordedDirectTarget.map {
                    resolvedDriveTarget == $0
                } == true
            if resolvedDriveTarget == bridgeRoot.standardizedFileURL.path ||
                isOwnedDirectTarget {
                try fileManager.removeItem(at: driveLink)
            }
        }
        if removesReservation, fileManager.fileExists(atPath: bridgeRoot.path) {
            try fileManager.removeItem(at: bridgeRoot)
        } else if !removesReservation,
                  var assignment,
                  assignment.driveLinkOwnership == .forgePlay {
            assignment.version = DriveAssignment.currentVersion
            assignment.driveLinkOwnership = .external
            try writeAssignment(assignment, at: bridgeRoot)
        }
    }

    private func prepareBridgeRoot(
        for libraryRoot: URL,
        driveLetter: String,
        bridgeDirectory: URL,
        driveLinkOwnership: DriveLinkOwnership,
        isReservedOnly: Bool
    ) throws -> URL {
        let bridgeRoot = bridgeDirectory.appending(path: driveLetter, directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: bridgeRoot, withIntermediateDirectories: true)
            try FileSystemItemPolicy.requireNonSymlinkDirectory(bridgeRoot, fileManager: fileManager)
        } catch {
            throw SteamLibraryDriveBridgeError.bridgeDirectoryUnavailable(bridgeRoot)
        }

        if let assignment = try readAssignment(at: bridgeRoot),
           !assignmentMatches(assignment, libraryRoot: libraryRoot) {
            throw SteamLibraryDriveBridgeError.driveLetterOccupied(bridgeRoot)
        }

        let libraryLink = bridgeRoot.appending(path: Self.bridgeLibraryDirectoryName)
        if let existingTarget = try? fileManager.destinationOfSymbolicLink(atPath: libraryLink.path) {
            let resolved = resolvedSymlinkTarget(existingTarget, relativeTo: bridgeRoot)
            if resolved == libraryRoot.resolvingSymlinksInPath().standardizedFileURL.path {
                try writeAssignment(
                    for: libraryRoot,
                    at: bridgeRoot,
                    driveLinkOwnership: driveLinkOwnership,
                    isReservedOnly: isReservedOnly
                )
                return bridgeRoot
            }
            try fileManager.removeItem(at: libraryLink)
        } else if fileManager.fileExists(atPath: libraryLink.path) {
            throw SteamLibraryDriveBridgeError.driveLetterOccupied(libraryLink)
        }
        do {
            try fileManager.createSymbolicLink(at: libraryLink, withDestinationURL: libraryRoot)
        } catch {
            throw SteamLibraryDriveBridgeError.driveLetterOccupied(libraryLink)
        }
        try writeAssignment(
            for: libraryRoot,
            at: bridgeRoot,
            driveLinkOwnership: driveLinkOwnership,
            isReservedOnly: isReservedOnly
        )
        return bridgeRoot
    }

    private func installDriveLink(
        _ link: URL,
        target libraryRoot: URL,
        replacingLegacyBridge bridgeRoot: URL,
        bridgeDirectory: URL,
        replacingPreviousDirectTarget previousDirectTarget: URL?,
        ownsExistingDirectLink: Bool
    ) throws -> DriveLinkOwnership {
        if let existingTarget = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
            let resolved = resolvedSymlinkTarget(existingTarget, relativeTo: link.deletingLastPathComponent())
            if resolved == libraryRoot.resolvingSymlinksInPath().standardizedFileURL.path {
                return ownsExistingDirectLink ? .forgePlay : .external
            }
            let existingURL = URL(fileURLWithPath: resolved, isDirectory: true)
            guard resolved == bridgeRoot.standardizedFileURL.path ||
                    resolved == previousDirectTarget?.standardizedFileURL.path ||
                    (isURL(existingURL, containedBy: bridgeDirectory) &&
                        bridgeTargetsLibrary(
                            existingURL,
                            libraryRoot: libraryRoot,
                            bridgeDirectory: bridgeDirectory
                        )) else {
                throw SteamLibraryDriveBridgeError.driveLetterOccupied(link)
            }
            try fileManager.removeItem(at: link)
        } else if fileManager.fileExists(atPath: link.path) {
            throw SteamLibraryDriveBridgeError.driveLetterOccupied(link)
        }
        do {
            try fileManager.createSymbolicLink(at: link, withDestinationURL: libraryRoot)
        } catch {
            throw SteamLibraryDriveBridgeError.driveLetterOccupied(link)
        }
        return .forgePlay
    }

    private func bridgeTargetsLibrary(
        _ candidate: URL,
        libraryRoot: URL,
        bridgeDirectory: URL
    ) -> Bool {
        guard isURL(candidate, containedBy: bridgeDirectory) else { return false }
        let libraryLink = candidate.appending(path: Self.bridgeLibraryDirectoryName)
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: libraryLink.path) else {
            return false
        }
        return resolvedSymlinkTarget(target, relativeTo: candidate) ==
            libraryRoot.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func directDriveTarget(_ target: String, contains libraryRoot: URL) -> Bool {
        target == libraryRoot.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func isURL(_ candidate: URL, containedBy root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private nonisolated static func mappedMacRoot(forDrive drive: String, prefix: URL) -> URL? {
        let link = prefix
            .appending(path: "dosdevices", directoryHint: .isDirectory)
            .appending(path: "\(drive.lowercased()):")
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return nil
        }
        let targetURL = target.hasPrefix("/")
            ? URL(fileURLWithPath: target, isDirectory: true)
            : link.deletingLastPathComponent().appending(path: target, directoryHint: .isDirectory)
        return targetURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private nonisolated static let libraryDriveLetters: [String] = {
        (UnicodeScalar("d").value...UnicodeScalar("y").value).compactMap { scalar in
            UnicodeScalar(scalar).map { String(Character($0)) }
        }
    }()
}
