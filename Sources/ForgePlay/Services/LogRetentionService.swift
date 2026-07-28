import Darwin
import Foundation

struct LogCleanupResult: Hashable {
    var removedFiles: Int
    var freedBytes: Int64
}

private struct LogRetentionRoots: Sendable {
    var managedRoot: URL
    var logsRoot: URL
    var launchLogs: URL
}

private struct LaunchLogArtifact {
    var url: URL
    var modificationDate: Date
}

private struct LaunchLogRetentionUnit {
    var key: String
    var groupKeys: Set<String>
    var artifacts: [LaunchLogArtifact]
    var isProtected: Bool

    var modificationDate: Date {
        artifacts.map(\.modificationDate).max() ?? .distantPast
    }
}

private struct LaunchLogGroupEdge: Hashable {
    var first: String
    var second: String

    init(_ first: String, _ second: String) {
        if first <= second {
            self.first = first
            self.second = second
        } else {
            self.first = second
            self.second = first
        }
    }
}

private struct LaunchLogScanResult {
    var artifacts: [LaunchLogArtifact]
    var blockedGroupKeys: Set<String>
    var activeGroupKeys: Set<String>
    var relatedGroupEdges: Set<LaunchLogGroupEdge>
    var expiredEmptyGameRunDirectoriesByGroup: [String: URL]
}

private struct LaunchArtifactIdentity: Equatable {
    var device: UInt64
    var inode: UInt64
    var byteCount: Int64
    var modificationSeconds: Int64
    var modificationNanoseconds: Int64
    var changeSeconds: Int64
    var changeNanoseconds: Int64
    var flags: UInt32
}

private struct LaunchArtifactDeletionEntry {
    var artifact: LaunchLogArtifact
    var identity: LaunchArtifactIdentity
}

private struct LaunchArtifactDeletionPlan {
    var groupKeys: Set<String>
    var entries: [LaunchArtifactDeletionEntry]
    var directoryCandidates: Set<URL>
}

private struct LaunchGroupDisjointSet {
    private var parents: [String: String] = [:]

    mutating func insert(_ value: String) {
        if parents[value] == nil {
            parents[value] = value
        }
    }

    mutating func union(_ first: String, _ second: String) {
        insert(first)
        insert(second)
        let firstRoot = root(of: first)
        let secondRoot = root(of: second)
        guard firstRoot != secondRoot else { return }
        if firstRoot < secondRoot {
            parents[secondRoot] = firstRoot
        } else {
            parents[firstRoot] = secondRoot
        }
    }

    mutating func root(of value: String) -> String {
        insert(value)
        var current = value
        while let parent = parents[current], parent != current {
            current = parent
        }
        let root = current
        current = value
        while let parent = parents[current], parent != current {
            parents[current] = root
            current = parent
        }
        return root
    }
}

enum LogRetentionServiceError: LocalizedError {
    case scanFailed(URL, Error)
    case metadataReadFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .scanFailed(let url, let error):
            "로그 폴더를 검사하지 못했습니다: \(url.path). \(forgePlayTechnicalErrorSummary(error))"
        case .metadataReadFailed(let url, let error):
            "로그 파일 정보를 읽지 못했습니다: \(url.path). \(forgePlayTechnicalErrorSummary(error))"
        }
    }
}

@MainActor
final class LogRetentionService {
    private let pathManager: PathManager

    init(pathManager: PathManager) {
        self.pathManager = pathManager
    }

    func cleanup(retentionDays: Int, launchLogLimit: Int) throws -> LogCleanupResult {
        let roots = try resolvedRoots()
        return try LogRetentionWorker.cleanup(
            managedRoot: roots.managedRoot,
            logsRoot: roots.logsRoot,
            launchLogs: roots.launchLogs,
            retentionDays: retentionDays,
            launchLogLimit: launchLogLimit
        )
    }

    func cleanupInBackground(retentionDays: Int, launchLogLimit: Int) throws -> Task<LogCleanupResult, Error> {
        let roots = try resolvedRoots()
        return Task.detached(priority: .utility) {
            try LogRetentionWorker.cleanup(
                managedRoot: roots.managedRoot,
                logsRoot: roots.logsRoot,
                launchLogs: roots.launchLogs,
                retentionDays: retentionDays,
                launchLogLimit: launchLogLimit
            )
        }
    }

    private func resolvedRoots() throws -> LogRetentionRoots {
        guard let managedRoot = pathManager.rootURL else {
            throw PathManagerError.rootNotConfigured
        }
        return LogRetentionRoots(
            managedRoot: managedRoot,
            logsRoot: try pathManager.url(for: .logs),
            launchLogs: try pathManager.url(for: .launchLogs)
        )
    }
}

private enum LogRetentionWorker {
    private static let supportedLaunchArtifactExtensions = Set(["log", "txt", "json", "md", "png"])
    private static let maximumRunEvidenceBytes = 512 * 1_024
    private static let maximumRelatedRunEvidenceLinks = 64
    private static let maximumRelatedRunEvidencePathBytes = 4_096
    private static let emptyGameRunActivityLeaseDuration: TimeInterval = 15 * 60

    static func cleanup(
        managedRoot: URL,
        logsRoot: URL,
        launchLogs: URL,
        retentionDays: Int,
        launchLogLimit: Int,
        fileManager: FileManager = .default
    ) throws -> LogCleanupResult {
        try validateCleanupRoots(
            managedRoot: managedRoot,
            logsRoot: logsRoot,
            launchLogs: launchLogs,
            fileManager: fileManager
        )
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -max(retentionDays, 1),
            to: Date()
        ) ?? Date.distantPast
        var removedFiles = 0
        var freedBytes: Int64 = 0

        for url in try logFiles(under: logsRoot, fileManager: fileManager) {
            // Launch evidence is retained as an atomic run group below. Aging
            // files independently can otherwise orphan stdout, stderr, the
            // process sidecar, observation journal, or renderer artifacts.
            guard !isDescendant(url, of: launchLogs) else { continue }
            guard try shouldRemoveByAge(url, cutoff: cutoff) else { continue }
            let bytes = try removableFileSize(
                url,
                under: logsRoot,
                managedRoot: managedRoot,
                logsRoot: logsRoot,
                launchLogs: launchLogs,
                fileManager: fileManager
            )
            if try removeRegularFile(
                url,
                under: logsRoot,
                managedRoot: managedRoot,
                logsRoot: logsRoot,
                launchLogs: launchLogs,
                fileManager: fileManager
            ) {
                freedBytes += bytes
                removedFiles += 1
            }
        }

        try validateCleanupRoots(
            managedRoot: managedRoot,
            logsRoot: logsRoot,
            launchLogs: launchLogs,
            fileManager: fileManager
        )
        let launchScan = try scanLaunchLogs(under: launchLogs, fileManager: fileManager)
        let launchUnits = launchRetentionUnits(from: launchScan, launchLogs: launchLogs)
        let retainedUnitKeys = retainedLaunchUnitKeys(
            launchUnits,
            cutoff: cutoff,
            launchLogLimit: launchLogLimit
        )
        var directoryCleanupCandidates = Set<URL>()
        for unit in launchUnits where
            !retainedUnitKeys.contains(unit.key) && !unit.isProtected {
            // Scan the complete evidence graph again immediately before
            // planning deletion. New links, active markers, unsupported
            // siblings, or unsafe filesystem entries cancel this unit for the
            // current cleanup pass.
            guard let currentUnit = try currentDeletableLaunchUnit(
                matching: unit.groupKeys,
                under: launchLogs,
                cutoff: cutoff,
                launchLogLimit: launchLogLimit,
                fileManager: fileManager
            ) else {
                continue
            }
            let plan = try makeLaunchDeletionPlan(
                for: currentUnit,
                managedRoot: managedRoot,
                logsRoot: logsRoot,
                launchLogs: launchLogs,
                fileManager: fileManager
            )
            guard try launchDeletionPlanMatchesCurrentScan(
                plan,
                under: launchLogs,
                cutoff: cutoff,
                launchLogLimit: launchLogLimit,
                fileManager: fileManager
            ) else {
                continue
            }
            let result = try executeLaunchDeletionPlan(
                plan,
                managedRoot: managedRoot,
                logsRoot: logsRoot,
                launchLogs: launchLogs,
                fileManager: fileManager
            )
            removedFiles += result.removedFiles
            freedBytes += result.freedBytes
            directoryCleanupCandidates.formUnion(plan.directoryCandidates)
            for groupKey in plan.groupKeys {
                if let directory = launchScan.expiredEmptyGameRunDirectoriesByGroup[groupKey] {
                    directoryCleanupCandidates.insert(directory)
                }
            }
        }
        try removeEmptyCandidateDirectories(
            directoryCleanupCandidates,
            under: launchLogs,
            managedRoot: managedRoot,
            logsRoot: logsRoot,
            fileManager: fileManager
        )

        return LogCleanupResult(removedFiles: removedFiles, freedBytes: freedBytes)
    }

    private static func logFiles(under root: URL, fileManager: FileManager) throws -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else {
            return []
        }
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .fileSizeKey,
                .linkCountKey
            ],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw LogRetentionServiceError.scanFailed(root, CocoaError(.fileReadUnknown))
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .linkCountKey]
                )
            } catch {
                throw LogRetentionServiceError.metadataReadFailed(url, error)
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true,
                  supportedLaunchArtifactExtensions.contains(url.pathExtension.lowercased()) else {
                continue
            }
            if isHardlinkedRegularFile(values) {
                continue
            }
            files.append(url)
        }
        if let enumerationError {
            throw LogRetentionServiceError.scanFailed(root, enumerationError)
        }
        return files
    }

    private static func scanLaunchLogs(
        under root: URL,
        fileManager: FileManager
    ) throws -> LaunchLogScanResult {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .linkCountKey
            ],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw LogRetentionServiceError.scanFailed(root, CocoaError(.fileReadUnknown))
        }

        var artifacts: [LaunchLogArtifact] = []
        var blockedGroupKeys = Set<String>()
        var activeGroupKeys = Set<String>()
        var gameRunDirectories: [String: (url: URL, modificationDate: Date)] = [:]
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                    .linkCountKey
                ])
            } catch {
                throw LogRetentionServiceError.metadataReadFailed(url, error)
            }

            let groupKey = launchArtifactGroupKey(for: url, launchLogs: root)
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                blockedGroupKeys.insert(groupKey)
                continue
            }
            if values.isDirectory == true {
                if let runID = gameRunDirectoryUUID(for: url, launchLogs: root) {
                    guard let modificationDate = values.contentModificationDate else {
                        blockedGroupKeys.insert(runID)
                        continue
                    }
                    gameRunDirectories[runID] = (
                        url.standardizedFileURL,
                        modificationDate
                    )
                }
                continue
            }
            guard values.isRegularFile == true else {
                blockedGroupKeys.insert(groupKey)
                continue
            }
            if isHardlinkedRegularFile(values) {
                blockedGroupKeys.insert(groupKey)
                continue
            }
            guard supportedLaunchArtifactExtensions.contains(url.pathExtension.lowercased()) else {
                // An unrecognized sibling with the same run UUID may carry
                // evidence that this version does not understand. Deleting
                // only the recognized files would split that run's evidence.
                blockedGroupKeys.insert(groupKey)
                continue
            }
            guard let date = values.contentModificationDate else {
                throw LogRetentionServiceError.metadataReadFailed(
                    url,
                    CocoaError(.fileReadUnknown)
                )
            }
            artifacts.append(LaunchLogArtifact(url: url, modificationDate: date))
        }
        if let enumerationError {
            throw LogRetentionServiceError.scanFailed(root, enumerationError)
        }

        // An empty renderer directory is the only marker available during the
        // interval after a run is registered but before its first renderer log
        // is written. Keep that marker under a bounded lease so abandoned
        // directories cannot protect a run forever.
        let referenceDate = Date()
        var expiredEmptyGameRunDirectoriesByGroup: [String: URL] = [:]
        for (runID, directoryEntry) in gameRunDirectories {
            do {
                if try fileManager.contentsOfDirectory(atPath: directoryEntry.url.path).isEmpty {
                    if directoryEntry.modificationDate.addingTimeInterval(
                        emptyGameRunActivityLeaseDuration
                    ) > referenceDate {
                        activeGroupKeys.insert(runID)
                    } else {
                        expiredEmptyGameRunDirectoriesByGroup[runID] = directoryEntry.url
                    }
                }
            } catch {
                blockedGroupKeys.insert(runID)
            }
        }

        let safeEvidenceByPath = Dictionary(
            uniqueKeysWithValues: artifacts
                .filter { isProcessRunEvidenceURL($0.url) }
                .map { ($0.url.standardizedFileURL.path, $0) }
        )
        var relatedGroupEdges = Set<LaunchLogGroupEdge>()
        for artifact in safeEvidenceByPath.values {
            let groupKey = launchArtifactGroupKey(for: artifact.url, launchLogs: root)
            guard let runID = launchUUIDGroupKey(for: artifact.url, launchLogs: root) else {
                blockedGroupKeys.insert(groupKey)
                continue
            }
            guard let document = readProcessRunEvidenceForRetention(
                at: artifact.url,
                under: root,
                fileManager: fileManager
            ),
                  ProcessRunEvidenceDocument.readableSchemaVersions.contains(document.schemaVersion),
                  document.runIdentifier.lowercased() == runID,
                  UUID(uuidString: document.runIdentifier) != nil else {
                // A truncated, oversized, future-schema, or otherwise
                // incomplete sidecar cannot prove that the process is done or
                // that every related evidence edge has been observed.
                blockedGroupKeys.insert(runID)
                activeGroupKeys.insert(runID)
                continue
            }
            let relatedRunEvidenceLogs = document.relatedRunEvidenceLogs ?? []
            guard relatedRunEvidenceLogs.count <= maximumRelatedRunEvidenceLinks else {
                blockedGroupKeys.insert(runID)
                activeGroupKeys.insert(runID)
                continue
            }

            if processEvidenceMayStillBeActive(document, referenceDate: referenceDate) {
                activeGroupKeys.insert(runID)
            }

            var documentEdges = Set<LaunchLogGroupEdge>()
            var linksAreComplete = true
            for linkedPath in relatedRunEvidenceLogs {
                guard linkedPath.utf8.count <= maximumRelatedRunEvidencePathBytes,
                      linkedPath.hasPrefix("/") else {
                    linksAreComplete = false
                    break
                }
                let linkedURL = URL(fileURLWithPath: linkedPath).standardizedFileURL
                guard isDescendant(linkedURL, of: root),
                      isProcessRunEvidenceURL(linkedURL),
                      safeEvidenceByPath[linkedURL.path] != nil,
                      let linkedRunID = launchUUIDGroupKey(for: linkedURL, launchLogs: root) else {
                    linksAreComplete = false
                    break
                }
                documentEdges.insert(LaunchLogGroupEdge(runID, linkedRunID))
            }
            relatedGroupEdges.formUnion(documentEdges)
            if !linksAreComplete {
                blockedGroupKeys.insert(runID)
                activeGroupKeys.insert(runID)
            }
        }
        return LaunchLogScanResult(
            artifacts: artifacts,
            blockedGroupKeys: blockedGroupKeys,
            activeGroupKeys: activeGroupKeys,
            relatedGroupEdges: relatedGroupEdges,
            expiredEmptyGameRunDirectoriesByGroup: expiredEmptyGameRunDirectoriesByGroup
        )
    }

    private static func launchRetentionUnits(
        from scan: LaunchLogScanResult,
        launchLogs: URL
    ) -> [LaunchLogRetentionUnit] {
        let artifactsByGroup = Dictionary(grouping: scan.artifacts) {
            launchArtifactGroupKey(for: $0.url, launchLogs: launchLogs)
        }
        var allKeys = Set(artifactsByGroup.keys)
        allKeys.formUnion(scan.blockedGroupKeys)
        allKeys.formUnion(scan.activeGroupKeys)
        for edge in scan.relatedGroupEdges {
            allKeys.insert(edge.first)
            allKeys.insert(edge.second)
        }

        var groups = LaunchGroupDisjointSet()
        for key in allKeys {
            groups.insert(key)
        }
        for edge in scan.relatedGroupEdges {
            groups.union(edge.first, edge.second)
        }

        var keysByRoot: [String: Set<String>] = [:]
        for key in allKeys {
            keysByRoot[groups.root(of: key), default: []].insert(key)
        }
        return keysByRoot.compactMap { root, groupKeys in
            let artifacts = groupKeys.flatMap { artifactsByGroup[$0] ?? [] }
            guard !artifacts.isEmpty else { return nil }
            return LaunchLogRetentionUnit(
                key: root,
                groupKeys: groupKeys,
                artifacts: artifacts,
                isProtected: !groupKeys.isDisjoint(with: scan.blockedGroupKeys) ||
                    !groupKeys.isDisjoint(with: scan.activeGroupKeys)
            )
        }.sorted {
            if $0.modificationDate != $1.modificationDate {
                return $0.modificationDate > $1.modificationDate
            }
            return $0.key < $1.key
        }
    }

    private static func retainedLaunchUnitKeys(
        _ units: [LaunchLogRetentionUnit],
        cutoff: Date,
        launchLogLimit: Int
    ) -> Set<String> {
        Set(
            units
                .filter { $0.modificationDate >= cutoff }
                .prefix(max(launchLogLimit, 1))
                .map(\.key)
        )
    }

    private static func currentDeletableLaunchUnit(
        matching expectedGroupKeys: Set<String>,
        under launchLogs: URL,
        cutoff: Date,
        launchLogLimit: Int,
        fileManager: FileManager
    ) throws -> LaunchLogRetentionUnit? {
        let scan = try scanLaunchLogs(under: launchLogs, fileManager: fileManager)
        let units = launchRetentionUnits(from: scan, launchLogs: launchLogs)
        guard let unit = units.first(where: { !$0.groupKeys.isDisjoint(with: expectedGroupKeys) }),
              unit.groupKeys == expectedGroupKeys,
              !unit.isProtected,
              !retainedLaunchUnitKeys(
                  units,
                  cutoff: cutoff,
                  launchLogLimit: launchLogLimit
              ).contains(unit.key) else {
            return nil
        }
        return unit
    }

    private static func makeLaunchDeletionPlan(
        for unit: LaunchLogRetentionUnit,
        managedRoot: URL,
        logsRoot: URL,
        launchLogs: URL,
        fileManager: FileManager
    ) throws -> LaunchArtifactDeletionPlan {
        let sortedArtifacts = unit.artifacts.sorted {
            $0.url.standardizedFileURL.path < $1.url.standardizedFileURL.path
        }
        var entries: [LaunchArtifactDeletionEntry] = []
        var directoryCandidates = Set<URL>()
        for artifact in sortedArtifacts {
            try validateRemovableFile(
                artifact.url,
                under: launchLogs,
                managedRoot: managedRoot,
                logsRoot: logsRoot,
                launchLogs: launchLogs,
                fileManager: fileManager
            )
            entries.append(
                LaunchArtifactDeletionEntry(
                    artifact: artifact,
                    identity: try launchArtifactIdentity(at: artifact.url)
                )
            )
            // Capture the canonical parent while the file still exists. The
            // enumerator can spell macOS temporary paths with `/private/var`,
            // which cannot always be canonicalized after unlink.
            directoryCandidates.formUnion(
                cleanupDirectoryCandidates(afterRemoving: artifact.url, under: launchLogs)
            )
        }
        try validateLaunchDeletionEntries(
            entries,
            managedRoot: managedRoot,
            logsRoot: logsRoot,
            launchLogs: launchLogs,
            fileManager: fileManager
        )
        return LaunchArtifactDeletionPlan(
            groupKeys: unit.groupKeys,
            entries: entries,
            directoryCandidates: directoryCandidates
        )
    }

    private static func launchDeletionPlanMatchesCurrentScan(
        _ plan: LaunchArtifactDeletionPlan,
        under launchLogs: URL,
        cutoff: Date,
        launchLogLimit: Int,
        fileManager: FileManager
    ) throws -> Bool {
        guard let unit = try currentDeletableLaunchUnit(
            matching: plan.groupKeys,
            under: launchLogs,
            cutoff: cutoff,
            launchLogLimit: launchLogLimit,
            fileManager: fileManager
        ) else {
            return false
        }
        let plannedPaths = Set(plan.entries.map { $0.artifact.url.standardizedFileURL.path })
        let currentPaths = Set(unit.artifacts.map { $0.url.standardizedFileURL.path })
        return plannedPaths == currentPaths
    }

    private static func executeLaunchDeletionPlan(
        _ plan: LaunchArtifactDeletionPlan,
        managedRoot: URL,
        logsRoot: URL,
        launchLogs: URL,
        fileManager: FileManager
    ) throws -> LogCleanupResult {
        guard !plan.entries.isEmpty else {
            return LogCleanupResult(removedFiles: 0, freedBytes: 0)
        }

        // Validate every sibling before the first unlink, then every remaining
        // sibling again before each subsequent unlink. Thus every unsafe state
        // visible before deletion begins cancels the whole unit. POSIX does not
        // provide a transaction or rollback spanning independent paths: a new
        // mutation or unlink failure after an earlier unlink can still leave a
        // partial unit. We narrow that interval and surface the failure rather
        // than claiming stronger atomicity than the filesystem provides.
        try validateLaunchDeletionEntries(
            plan.entries,
            managedRoot: managedRoot,
            logsRoot: logsRoot,
            launchLogs: launchLogs,
            fileManager: fileManager
        )
        var removedFiles = 0
        var freedBytes: Int64 = 0
        for index in plan.entries.indices {
            try validateLaunchDeletionEntries(
                Array(plan.entries[index...]),
                managedRoot: managedRoot,
                logsRoot: logsRoot,
                launchLogs: launchLogs,
                fileManager: fileManager
            )
            let entry = plan.entries[index]
            let result = entry.artifact.url.path.withCString { Darwin.unlink($0) }
            guard result == 0 else {
                let failure = errno
                throw LogRetentionServiceError.scanFailed(
                    entry.artifact.url,
                    POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
                )
            }
            removedFiles += 1
            freedBytes += entry.identity.byteCount
        }
        return LogCleanupResult(removedFiles: removedFiles, freedBytes: freedBytes)
    }

    private static func validateLaunchDeletionEntries(
        _ entries: [LaunchArtifactDeletionEntry],
        managedRoot: URL,
        logsRoot: URL,
        launchLogs: URL,
        fileManager: FileManager
    ) throws {
        try validateCleanupRoots(
            managedRoot: managedRoot,
            logsRoot: logsRoot,
            launchLogs: launchLogs,
            fileManager: fileManager
        )
        for entry in entries {
            let parent = entry.artifact.url.deletingLastPathComponent()
            guard fileManager.isWritableFile(atPath: parent.path) else {
                throw LogRetentionServiceError.scanFailed(
                    parent,
                    CocoaError(.fileWriteNoPermission)
                )
            }
            try validateRemovableFile(
                entry.artifact.url,
                under: launchLogs,
                managedRoot: managedRoot,
                logsRoot: logsRoot,
                launchLogs: launchLogs,
                fileManager: fileManager
            )
            guard try launchArtifactIdentity(at: entry.artifact.url) == entry.identity else {
                throw LogRetentionServiceError.metadataReadFailed(
                    entry.artifact.url,
                    CocoaError(.fileReadUnknown)
                )
            }
        }
    }

    private static func readProcessRunEvidenceForRetention(
        at url: URL,
        under root: URL,
        fileManager: FileManager
    ) -> ProcessRunEvidenceDocument? {
        guard isDescendant(url, of: root),
              FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                  from: root,
                  to: url,
                  fileManager: fileManager
              ) else {
            return nil
        }
        do {
            let data = try boundedRegularFileData(
                at: url,
                maximumBytes: maximumRunEvidenceBytes
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ProcessRunEvidenceDocument.self, from: data)
        } catch {
            return nil
        }
    }

    private static func processEvidenceMayStillBeActive(
        _ document: ProcessRunEvidenceDocument,
        referenceDate: Date
    ) -> Bool {
        guard document.endedAt >= document.startedAt,
              document.durationMilliseconds >= 0 else {
            return true
        }
        let requiresLease: Bool
        switch document.outcome {
        case .runningDetached, .unknown:
            requiresLease = true
        case .exited, .signaled, .timedOut:
            requiresLease = !document.waitedForExit
        case .preflightFailed, .spawnFailed:
            return false
        }
        guard requiresLease else { return false }

        let leaseAnchor = document.finalizedAt ?? document.endedAt
        guard leaseAnchor >= document.startedAt else { return true }
        let maximumLeaseExpiration = leaseAnchor.addingTimeInterval(
            ProcessRunEvidenceDocument.defaultActivityLeaseDuration
        )
        let requestedLeaseExpiration = document.activityLeaseExpiresAt ?? maximumLeaseExpiration
        return min(requestedLeaseExpiration, maximumLeaseExpiration) > referenceDate
    }

    private static func boundedRegularFileData(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        let initialIdentity = try launchArtifactIdentity(forDescriptor: descriptor, url: url)
        guard initialIdentity.byteCount >= 0,
              initialIdentity.byteCount <= Int64(maximumBytes) else {
            throw CocoaError(.fileReadTooLarge)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(16_384, maximumBytes + 1))
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, remaining))
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumBytes,
              try launchArtifactIdentity(forDescriptor: descriptor, url: url) == initialIdentity else {
            throw CocoaError(.fileReadUnknown)
        }
        return data
    }

    private static func launchArtifactIdentity(at url: URL) throws -> LaunchArtifactIdentity {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        guard result == 0 else {
            throw LogRetentionServiceError.metadataReadFailed(
                url,
                POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            )
        }
        return try launchArtifactIdentity(from: status, url: url)
    }

    private static func launchArtifactIdentity(
        forDescriptor descriptor: Int32,
        url: URL
    ) throws -> LaunchArtifactIdentity {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try launchArtifactIdentity(from: status, url: url)
    }

    private static func launchArtifactIdentity(
        from status: stat,
        url: URL
    ) throws -> LaunchArtifactIdentity {
        let unlinkBlockingFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_flags & unlinkBlockingFlags == 0 else {
            throw FileSystemItemPolicyError.notRegularNonSymlinkFile(url)
        }
        return LaunchArtifactIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            byteCount: Int64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changeSeconds: Int64(status.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(status.st_ctimespec.tv_nsec),
            flags: status.st_flags
        )
    }

    private static func launchArtifactGroupKey(for url: URL, launchLogs: URL) -> String {
        if let runID = launchUUIDGroupKey(for: url, launchLogs: launchLogs) {
            return runID
        }
        let launchPath = launchLogs.standardizedFileURL.path
        let artifactPath = url.standardizedFileURL.path
        guard artifactPath.hasPrefix(launchPath + "/") else {
            return artifactPath
        }
        let relativePath = String(artifactPath.dropFirst(launchPath.count + 1))
        let components = relativePath.split(separator: "/").map(String.init)
        return components.first ?? relativePath
    }

    private static func launchUUIDGroupKey(for url: URL, launchLogs: URL) -> String? {
        let launchPath = launchLogs.standardizedFileURL.path
        let artifactPath = url.standardizedFileURL.path
        guard artifactPath.hasPrefix(launchPath + "/") else { return nil }
        let relativePath = String(artifactPath.dropFirst(launchPath.count + 1))
        let components = relativePath.split(separator: "/").map(String.init)
        if components.count >= 2,
           components[0] == "GameRuns",
           UUID(uuidString: components[1]) != nil {
            return components[1].lowercased()
        }
        guard let topLevelName = components.first else { return nil }
        let uuidPattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
        if let uuidRange = topLevelName.range(of: uuidPattern, options: .regularExpression) {
            return String(topLevelName[uuidRange]).lowercased()
        }
        return nil
    }

    private static func gameRunDirectoryUUID(for url: URL, launchLogs: URL) -> String? {
        let launchPath = launchLogs.standardizedFileURL.path
        let directoryPath = url.standardizedFileURL.path
        guard directoryPath.hasPrefix(launchPath + "/") else { return nil }
        let relativePath = String(directoryPath.dropFirst(launchPath.count + 1))
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count == 2,
              components[0] == "GameRuns",
              UUID(uuidString: components[1]) != nil else {
            return nil
        }
        return components[1].lowercased()
    }

    private static func isProcessRunEvidenceURL(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(".run.json")
    }

    private static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func cleanupDirectoryCandidates(
        afterRemoving artifact: URL,
        under root: URL
    ) -> Set<URL> {
        let root = root.standardizedFileURL
        var directory = artifact.standardizedFileURL.deletingLastPathComponent()
        var candidates = Set<URL>()
        while directory.path != root.path, isDescendant(directory, of: root) {
            candidates.insert(directory)
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return candidates
    }

    private static func removeEmptyCandidateDirectories(
        _ candidates: Set<URL>,
        under root: URL,
        managedRoot: URL,
        logsRoot: URL,
        fileManager: FileManager
    ) throws {
        for directory in candidates.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            try validateCleanupRoots(
                managedRoot: managedRoot,
                logsRoot: logsRoot,
                launchLogs: root,
                fileManager: fileManager
            )
            guard isDescendant(directory, of: root),
                  directory.standardizedFileURL.path != root.standardizedFileURL.path else {
                throw LogRetentionServiceError.scanFailed(
                    directory,
                    FileSystemItemPolicyError.notNonSymlinkDirectory(directory)
                )
            }
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            do {
                guard FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                    from: root,
                    to: directory.appending(path: ".forgeplay-retention-boundary"),
                    fileManager: fileManager
                ) else {
                    throw FileSystemItemPolicyError.notNonSymlinkDirectory(directory)
                }
            } catch {
                throw LogRetentionServiceError.scanFailed(directory, error)
            }
            let contents: [String]
            do {
                contents = try fileManager.contentsOfDirectory(atPath: directory.path)
            } catch {
                throw LogRetentionServiceError.scanFailed(directory, error)
            }
            if contents.isEmpty {
                let result = directory.path.withCString { Darwin.rmdir($0) }
                if result != 0 {
                    let failure = errno
                    if failure == ENOENT || failure == ENOTEMPTY {
                        continue
                    }
                    throw LogRetentionServiceError.scanFailed(
                        directory,
                        POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
                    )
                }
            }
        }
    }

    private static func validateCleanupRoots(
        managedRoot: URL,
        logsRoot: URL,
        launchLogs: URL,
        fileManager: FileManager
    ) throws {
        let managedRoot = managedRoot.standardizedFileURL
        let logsRoot = logsRoot.standardizedFileURL
        let launchLogs = launchLogs.standardizedFileURL
        guard logsRoot.path.hasPrefix(managedRoot.path + "/"),
              launchLogs.path.hasPrefix(logsRoot.path + "/") else {
            throw LogRetentionServiceError.scanFailed(
                launchLogs,
                FileSystemItemPolicyError.notNonSymlinkDirectory(launchLogs)
            )
        }
        do {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(
                managedRoot,
                fileManager: fileManager
            )
            guard FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                from: managedRoot,
                to: logsRoot.appending(path: ".forgeplay-retention-boundary"),
                fileManager: fileManager
            ) else {
                throw FileSystemItemPolicyError.notNonSymlinkDirectory(logsRoot)
            }
        } catch {
            throw LogRetentionServiceError.scanFailed(logsRoot, error)
        }
        do {
            try FileSystemItemPolicy.requireNonSymlinkDirectory(
                logsRoot,
                fileManager: fileManager
            )
            guard fileManager.isReadableFile(atPath: logsRoot.path) else {
                throw CocoaError(.fileReadNoPermission)
            }
        } catch {
            throw LogRetentionServiceError.scanFailed(logsRoot, error)
        }
        do {
            guard FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                from: logsRoot,
                to: launchLogs.appending(path: ".forgeplay-retention-boundary"),
                fileManager: fileManager
            ) else {
                throw FileSystemItemPolicyError.notNonSymlinkDirectory(launchLogs)
            }
        } catch {
            throw LogRetentionServiceError.scanFailed(launchLogs, error)
        }
    }

    private static func removableFileSize(
        _ url: URL,
        under root: URL,
        managedRoot: URL,
        logsRoot: URL,
        launchLogs: URL,
        fileManager: FileManager
    ) throws -> Int64 {
        try validateRemovableFile(
            url,
            under: root,
            managedRoot: managedRoot,
            logsRoot: logsRoot,
            launchLogs: launchLogs,
            fileManager: fileManager
        )
        return try fileSize(url)
    }

    private static func removeRegularFile(
        _ url: URL,
        under root: URL,
        managedRoot: URL,
        logsRoot: URL,
        launchLogs: URL,
        fileManager: FileManager
    ) throws -> Bool {
        try validateRemovableFile(
            url,
            under: root,
            managedRoot: managedRoot,
            logsRoot: logsRoot,
            launchLogs: launchLogs,
            fileManager: fileManager
        )
        let result = url.path.withCString { Darwin.unlink($0) }
        if result == 0 { return true }
        let failure = errno
        if failure == ENOENT { return false }
        throw LogRetentionServiceError.scanFailed(
            url,
            POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        )
    }

    private static func validateRemovableFile(
        _ url: URL,
        under root: URL,
        managedRoot: URL,
        logsRoot: URL,
        launchLogs: URL,
        fileManager: FileManager
    ) throws {
        try validateCleanupRoots(
            managedRoot: managedRoot,
            logsRoot: logsRoot,
            launchLogs: launchLogs,
            fileManager: fileManager
        )
        guard isDescendant(url, of: root),
              FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                  from: root,
                  to: url,
                  fileManager: fileManager
              ) else {
            throw LogRetentionServiceError.scanFailed(
                url,
                FileSystemItemPolicyError.notNonSymlinkDirectory(url.deletingLastPathComponent())
            )
        }
        do {
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(
                url,
                fileManager: fileManager
            )
        } catch {
            throw LogRetentionServiceError.metadataReadFailed(url, error)
        }
    }

    private static func shouldRemoveByAge(_ url: URL, cutoff: Date) throws -> Bool {
        let path = url.path
        if path.contains("/SupportBundles/") {
            return false
        }
        return try modificationDate(url) < cutoff
    }

    private static func modificationDate(_ url: URL) throws -> Date {
        do {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let date = values.contentModificationDate else {
                throw LogRetentionServiceError.metadataReadFailed(url, CocoaError(.fileReadUnknown))
            }
            return date
        } catch let error as LogRetentionServiceError {
            throw error
        } catch {
            throw LogRetentionServiceError.metadataReadFailed(url, error)
        }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize else {
                throw LogRetentionServiceError.metadataReadFailed(url, CocoaError(.fileReadUnknown))
            }
            return Int64(fileSize)
        } catch let error as LogRetentionServiceError {
            throw error
        } catch {
            throw LogRetentionServiceError.metadataReadFailed(url, error)
        }
    }

    private static func isHardlinkedRegularFile(_ values: URLResourceValues) -> Bool {
        values.isRegularFile == true && (values.linkCount ?? 1) > 1
    }
}
