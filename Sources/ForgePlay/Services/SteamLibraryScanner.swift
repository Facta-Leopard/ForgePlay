import Foundation

enum SteamLibraryRootDiscoveryError: Error, Hashable, Sendable {
    case traversalFailed(URL, String)
    case noVerifiedSteamLibrary(URL, skippedPaths: [String])
    case ancestorAuthorizationRequired(selectedRoot: URL, requiredRoot: URL)
}

enum SteamLibraryRootDiscoveryResolution: String, Hashable, Sendable {
    case directLibraryRoot
    case selectedSteamApps
    case selectedCommon
    case selectedInstalledGame
    case immediateChildLibraries
}

struct SteamLibraryRootDiscoveryResult: Hashable, Sendable {
    var selectedRoot: URL
    var libraryRoots: [URL]
    var skippedInputPaths: Set<String>
    var resolution: SteamLibraryRootDiscoveryResolution?
    var failure: SteamLibraryRootDiscoveryError?

    var isComplete: Bool {
        failure == nil && skippedInputPaths.isEmpty
    }

    func requireVerifiedLibraryRoots() throws -> [URL] {
        if let failure {
            throw failure
        }
        guard !libraryRoots.isEmpty else {
            throw SteamLibraryRootDiscoveryError.noVerifiedSteamLibrary(
                selectedRoot,
                skippedPaths: skippedInputPaths.sorted()
            )
        }
        return libraryRoots
    }
}

struct SteamLibraryScanResult: Hashable {
    var games: [SteamGame]
    var skippedInputPaths: Set<String>

    var isComplete: Bool {
        skippedInputPaths.isEmpty
    }

    var skippedInputCount: Int {
        skippedInputPaths.count
    }

    func allowsRemovingStaleReferences(whenStorageAccessIsComplete: Bool) -> Bool {
        whenStorageAccessIsComplete && isComplete
    }

    func hasReferencesAfterScan(
        existingCount: Int,
        whenStorageAccessIsComplete: Bool
    ) -> Bool {
        !games.isEmpty ||
            (!allowsRemovingStaleReferences(whenStorageAccessIsComplete: whenStorageAccessIsComplete) &&
                existingCount > 0)
    }
}

final class SteamLibraryScanner: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func possibleLibraryRoots(defaultSteamLibrary: URL, steamSharedPrefix: URL) -> [URL] {
        [
            defaultSteamLibrary,
            steamSharedPrefix.appending(path: "drive_c/Program Files (x86)/Steam"),
            steamSharedPrefix.appending(path: "drive_c/Program Files (x86)/Steam/steamapps")
        ]
    }

    func scanInstalledGames(roots: [URL], prefixURL: URL?) throws -> [SteamGame] {
        try scanInstalledGamesResult(roots: roots, prefixURL: prefixURL).games
    }

    func scanInstalledGamesResult(roots: [URL], prefixURL: URL?) throws -> SteamLibraryScanResult {
        var libraries = Set<URL>()
        var declaredLibraryPaths = Set<String>()
        var skippedInputPaths = Set<String>()

        for root in roots {
            guard try isExistingNonSymlinkDirectory(root) else {
                if fileManager.fileExists(atPath: root.path) ||
                    (try? fileManager.destinationOfSymbolicLink(atPath: root.path)) != nil {
                    skippedInputPaths.insert(root.standardizedFileURL.path)
                }
                continue
            }
            let rootSteamApps = try steamAppsDirectory(
                for: root,
                skippedInputPaths: &skippedInputPaths
            )
            let directLibraryFolders = root.appending(path: "libraryfolders.vdf")
            if let rootSteamApps {
                let libraryFolders = rootSteamApps.appending(path: "libraryfolders.vdf")
                let libraryRoot = rootSteamApps.deletingLastPathComponent()
                if fileManager.fileExists(atPath: libraryFolders.path) {
                    if try SteamVDFFileReader.isReadableTextFile(
                        libraryFolders,
                        maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes
                    ) {
                        let declaredLibraries = try parseLibraryFolders(
                            libraryFolders,
                            prefixURL: prefixURL,
                            skippedInputPaths: &skippedInputPaths
                        )
                        libraries.formUnion(declaredLibraries)
                        declaredLibraryPaths.formUnion(
                            declaredLibraries.map { $0.standardizedFileURL.path }
                        )
                    } else {
                        skippedInputPaths.insert(libraryFolders.standardizedFileURL.path)
                    }
                }
                libraries.insert(libraryRoot)
            } else if fileManager.fileExists(atPath: directLibraryFolders.path) {
                if try SteamVDFFileReader.isReadableTextFile(
                    directLibraryFolders,
                    maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes
                ) {
                    let declaredLibraries = try parseLibraryFolders(
                        directLibraryFolders,
                        prefixURL: prefixURL,
                        skippedInputPaths: &skippedInputPaths
                    )
                    libraries.formUnion(declaredLibraries)
                    declaredLibraryPaths.formUnion(
                        declaredLibraries.map { $0.standardizedFileURL.path }
                    )
                    libraries.insert(root.deletingLastPathComponent())
                } else {
                    skippedInputPaths.insert(directLibraryFolders.standardizedFileURL.path)
                }
            }
        }

        var gamesByAppID: [String: SteamGame] = [:]
        for library in libraries.sorted(by: {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }) {
            let steamapps = library.lastPathComponent == "steamapps" ? library : library.appending(path: "steamapps")
            guard try isExistingNonSymlinkDirectory(steamapps) else {
                if declaredLibraryPaths.contains(library.standardizedFileURL.path) ||
                    fileManager.fileExists(atPath: steamapps.path) ||
                    (try? fileManager.destinationOfSymbolicLink(atPath: steamapps.path)) != nil {
                    skippedInputPaths.insert(steamapps.standardizedFileURL.path)
                }
                continue
            }
            let candidates: [URL]
            do {
                candidates = try fileManager.contentsOfDirectory(
                    at: steamapps,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                throw SteamLibraryScanError.scanFailed(steamapps, forgePlayTechnicalErrorSummary(error))
            }

            for manifest in candidates where manifest.lastPathComponent.hasPrefix("appmanifest_") && manifest.pathExtension == "acf" {
                guard try SteamVDFFileReader.isReadableTextFile(
                    manifest,
                    maxBytes: SteamVDFFileReader.maxManifestBytes
                ) else {
                    skippedInputPaths.insert(manifest.standardizedFileURL.path)
                    continue
                }
                if let game = try SteamManifestReader.parseManifest(manifest, libraryPath: library) {
                    let installDirectory = library
                        .appending(path: "steamapps/common", directoryHint: .isDirectory)
                        .appending(path: game.installDir, directoryHint: .isDirectory)
                    guard try isExistingNonSymlinkDirectory(installDirectory) else {
                        continue
                    }
                    if let existing = gamesByAppID[game.steamAppId] {
                        gamesByAppID[game.steamAppId] = preferredGame(existing, game)
                    } else {
                        gamesByAppID[game.steamAppId] = game
                    }
                }
            }
        }

        let games = gamesByAppID.values.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            if $0.steamAppId != $1.steamAppId { return $0.steamAppId < $1.steamAppId }
            return $0.manifestPath.localizedStandardCompare($1.manifestPath) == .orderedAscending
        }
        return SteamLibraryScanResult(
            games: games,
            skippedInputPaths: skippedInputPaths
        )
    }

    func normalizedLibraryRoots(for selectedURL: URL) -> [URL] {
        discoverLibraryRoots(for: selectedURL).libraryRoots
    }

    func discoverLibraryRoots(
        for selectedURL: URL
    ) -> SteamLibraryRootDiscoveryResult {
        let url = selectedURL.standardizedFileURL
        if let explicitSelection = explicitLibraryRoot(for: url) {
            guard isVerifiedLibraryRoot(explicitSelection.root) else {
                return SteamLibraryRootDiscoveryResult(
                    selectedRoot: url,
                    libraryRoots: [],
                    skippedInputPaths: [explicitSelection.root
                        .appending(path: "steamapps", directoryHint: .isDirectory)
                        .standardizedFileURL.path],
                    resolution: nil,
                    failure: .noVerifiedSteamLibrary(
                        url,
                        skippedPaths: [explicitSelection.root
                            .appending(path: "steamapps", directoryHint: .isDirectory)
                            .standardizedFileURL.path]
                    )
                )
            }
            return SteamLibraryRootDiscoveryResult(
                selectedRoot: url,
                libraryRoots: [explicitSelection.root],
                skippedInputPaths: [],
                resolution: explicitSelection.resolution,
                failure: nil
            )
        }

        if isVerifiedLibraryRoot(url) {
            return SteamLibraryRootDiscoveryResult(
                selectedRoot: url,
                libraryRoots: [url],
                skippedInputPaths: [],
                resolution: .directLibraryRoot,
                failure: nil
            )
        }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            let reason = forgePlayTechnicalErrorSummary(error)
            return SteamLibraryRootDiscoveryResult(
                selectedRoot: url,
                libraryRoots: [],
                skippedInputPaths: [url.path],
                resolution: nil,
                failure: .traversalFailed(url, reason)
            )
        }

        var skippedInputPaths = Set<String>()
        var childLibraries: [URL] = []
        for child in children {
            let values: URLResourceValues
            do {
                values = try child.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
            } catch {
                skippedInputPaths.insert(child.standardizedFileURL.path)
                continue
            }
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  FileSystemItemPolicy.isNonSymlinkDirectory(
                      child,
                      fileManager: fileManager
                  ) else {
                continue
            }
            guard isVerifiedLibraryRoot(child) else { continue }
            childLibraries.append(child.standardizedFileURL)
        }

        if !childLibraries.isEmpty {
            var seenPaths = Set<String>()
            let verified = childLibraries.filter {
                seenPaths.insert($0.path).inserted
            }.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            return SteamLibraryRootDiscoveryResult(
                selectedRoot: url,
                libraryRoots: verified,
                skippedInputPaths: skippedInputPaths,
                resolution: .immediateChildLibraries,
                failure: nil
            )
        }

        let unverifiedPath = url
            .appending(path: "steamapps", directoryHint: .isDirectory)
            .standardizedFileURL.path
        skippedInputPaths.insert(unverifiedPath)
        let sortedSkippedPaths = skippedInputPaths.sorted()
        return SteamLibraryRootDiscoveryResult(
            selectedRoot: url,
            libraryRoots: [],
            skippedInputPaths: skippedInputPaths,
            resolution: nil,
            failure: .noVerifiedSteamLibrary(
                url,
                skippedPaths: sortedSkippedPaths
            )
        )
    }

    private func isVerifiedLibraryRoot(_ root: URL) -> Bool {
        FileSystemItemPolicy.isNonSymlinkDirectory(
            root.appending(path: "steamapps", directoryHint: .isDirectory),
            fileManager: fileManager
        )
    }

    private func explicitLibraryRoot(
        for selectedURL: URL
    ) -> (
        root: URL,
        resolution: SteamLibraryRootDiscoveryResolution
    )? {
        let url = selectedURL.standardizedFileURL
        if url.lastPathComponent.lowercased() == "steamapps" {
            return (
                url.deletingLastPathComponent().standardizedFileURL,
                .selectedSteamApps
            )
        }
        if url.lastPathComponent.lowercased() == "common",
           url.deletingLastPathComponent()
               .lastPathComponent.lowercased() == "steamapps" {
            return (
                url.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .standardizedFileURL,
                .selectedCommon
            )
        }
        if url.deletingLastPathComponent()
            .lastPathComponent.lowercased() == "common",
           url.deletingLastPathComponent()
               .deletingLastPathComponent()
               .lastPathComponent.lowercased() == "steamapps" {
            return (
                url.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .standardizedFileURL,
                .selectedInstalledGame
            )
        }
        return nil
    }

    private func steamAppsDirectory(
        for libraryRootOrSteamApps: URL,
        skippedInputPaths: inout Set<String>
    ) throws -> URL? {
        let candidate = libraryRootOrSteamApps.lastPathComponent.lowercased() == "steamapps"
            ? libraryRootOrSteamApps
            : libraryRootOrSteamApps.appending(path: "steamapps", directoryHint: .isDirectory)
        guard try isExistingNonSymlinkDirectory(candidate) else {
            if fileManager.fileExists(atPath: candidate.path) ||
                (try? fileManager.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
                skippedInputPaths.insert(candidate.standardizedFileURL.path)
            }
            return nil
        }
        return candidate
    }

    private func preferredGame(_ lhs: SteamGame, _ rhs: SteamGame) -> SteamGame {
        let lhsUpdated = lhs.lastUpdated ?? .distantPast
        let rhsUpdated = rhs.lastUpdated ?? .distantPast
        if lhsUpdated != rhsUpdated { return lhsUpdated > rhsUpdated ? lhs : rhs }
        if lhs.sizeOnDisk != rhs.sizeOnDisk { return lhs.sizeOnDisk > rhs.sizeOnDisk ? lhs : rhs }
        return lhs.manifestPath.localizedStandardCompare(rhs.manifestPath) != .orderedDescending
            ? lhs
            : rhs
    }

    private func isExistingNonSymlinkDirectory(_ url: URL) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        do {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(url, fileManager: fileManager)
            return true
        } catch FileSystemItemPolicyError.notNonSymlinkDirectory {
            return false
        } catch FileSystemItemPolicyError.metadataReadFailed(_, let message) {
            throw SteamLibraryScanError.metadataReadFailed(url, message)
        } catch {
            throw SteamLibraryScanError.metadataReadFailed(url, forgePlayTechnicalErrorSummary(error))
        }
    }

    private func parseLibraryFolders(
        _ url: URL,
        prefixURL: URL?,
        skippedInputPaths: inout Set<String>
    ) throws -> Set<URL> {
        guard let text = try SteamVDFFileReader.readText(url, maxBytes: SteamVDFFileReader.maxLibraryFoldersBytes) else {
            return []
        }
        let parsed = try VDFParser().parse(text)
        guard let root = parsed["libraryfolders"]?.objectValue else {
            return []
        }

        var libraries = Set<URL>()
        for value in root.values {
            if case .object(let object) = value,
               let path = object["path"]?.stringValue {
                guard let libraryURL = SteamLibraryDriveMapper.validatedMacURL(
                    fromSteamLibraryPath: path,
                    prefix: prefixURL
                ) else {
                    skippedInputPaths.insert(url.standardizedFileURL.path)
                    continue
                }
                libraries.insert(libraryURL)
            }
        }
        return libraries
    }
}
