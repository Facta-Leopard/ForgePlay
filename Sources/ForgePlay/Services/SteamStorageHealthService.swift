import Darwin
import Foundation

struct SteamStorageMountSnapshot: Identifiable, Hashable, Sendable {
    var id: String
    var path: String
    var bookmark: Data?

    init(id: String, path: String, bookmark: Data?) {
        self.id = id
        self.path = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        self.bookmark = bookmark
    }

    @MainActor
    init(record: SteamStorageMountRecord) {
        self.init(id: record.id, path: record.path, bookmark: record.bookmark)
    }
}

enum SteamStorageHealthStatus: String, Hashable, Sendable {
    case healthy
    case degraded
    case unavailable
    case reconnectRequired
}

enum SteamStorageAccessStage: String, CaseIterable, Hashable, Sendable {
    case bookmarkCreation
    case bookmarkResolution
    case securityScope
    case directoryValidation
    case directoryListing
    case temporaryFileWrite
    case temporaryFileRead
    case temporaryFileDeletion
    case bookmarkRefresh
}

struct SteamStorageHealthReport: Identifiable, Hashable, Sendable {
    var id: String { mountID }
    var mountID: String
    var savedPath: String
    var resolvedPath: String?
    var status: SteamStorageHealthStatus
    var failedStage: SteamStorageAccessStage?
    var bookmarkIsStale: Bool
    var technicalDetail: String?

    var requiresReconnect: Bool {
        status != .healthy
    }
}

struct SteamStorageValidatedSelection: Hashable, Sendable {
    var root: URL
    var bookmark: Data
    var resolvedURL: URL
}

struct SteamStorageAccessValidationError:
    Error,
    Equatable,
    Sendable,
    ForgePlayTechnicalDescribingError
{
    var stage: SteamStorageAccessStage
    var path: String
    var reason: String

    var forgePlayTechnicalDescription: String {
        [
            "Steam storage access validation failed",
            "stage=\(stage.rawValue)",
            "path=\(path)",
            "reason=\(reason)"
        ].joined(separator: "; ")
    }
}

struct SteamStorageAccessProbeError: Error, Equatable, Sendable {
    var stage: SteamStorageAccessStage
    var path: String
    var reason: String
}

struct SteamStorageHealthService: Sendable {
    struct Dependencies: Sendable {
        var bookmarkCreator: @Sendable (URL) throws -> Data
        var bookmarkResolver: @Sendable (Data) throws -> SecurityScopedBookmarkResolvedURL
        var securityScopeStarter: @Sendable (URL) -> Bool
        var securityScopeStopper: @Sendable (URL) -> Void
        var directoryProbe: @Sendable (URL) throws -> Void

        static let live = Dependencies(
            bookmarkCreator: { try SecurityScopedBookmarkPolicy.bookmarkData(for: $0) },
            bookmarkResolver: { try SecurityScopedBookmarkPolicy.resolvedURL(fromBookmarkData: $0) },
            securityScopeStarter: { $0.startAccessingSecurityScopedResource() },
            securityScopeStopper: { $0.stopAccessingSecurityScopedResource() },
            directoryProbe: { try SteamStorageDirectoryProbe.verify(at: $0) }
        )
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func validateSelection(
        _ selectedURL: URL,
        requiresSecurityScope: Bool
    ) async throws -> SteamStorageValidatedSelection {
        let dependencies = dependencies
        let validationTask = Task.detached(priority: .userInitiated) {
            try Self.validateSelectionSynchronously(
                selectedURL,
                requiresSecurityScope: requiresSecurityScope,
                dependencies: dependencies
            )
        }
        return try await withTaskCancellationHandler {
            try await validationTask.value
        } onCancel: {
            validationTask.cancel()
        }
    }

    func diagnose(
        _ snapshots: [SteamStorageMountSnapshot],
        requiresSecurityScope: Bool
    ) async throws -> [SteamStorageHealthReport] {
        let dependencies = dependencies
        return try await withThrowingTaskGroup(
            of: SteamStorageHealthReport.self,
            returning: [SteamStorageHealthReport].self
        ) { group in
            for snapshot in snapshots {
                group.addTask(priority: .utility) {
                    try Task.checkCancellation()
                    return try Self.diagnoseSynchronously(
                        snapshot,
                        requiresSecurityScope: requiresSecurityScope,
                        dependencies: dependencies
                    )
                }
            }

            var reportsByID: [String: SteamStorageHealthReport] = [:]
            for try await report in group {
                reportsByID[report.mountID] = report
            }
            try Task.checkCancellation()
            return snapshots.compactMap { reportsByID[$0.id] }
        }
    }

    private nonisolated static func validateSelectionSynchronously(
        _ selectedURL: URL,
        requiresSecurityScope: Bool,
        dependencies: Dependencies
    ) throws -> SteamStorageValidatedSelection {
        let selected = selectedURL.standardizedFileURL
        try Task.checkCancellation()

        let didStartSelectedScope = dependencies.securityScopeStarter(selected)
        guard didStartSelectedScope || !requiresSecurityScope else {
            throw validationError(
                stage: .securityScope,
                url: selected,
                reason: "selected folder security-scoped access could not be started"
            )
        }
        defer {
            if didStartSelectedScope {
                dependencies.securityScopeStopper(selected)
            }
        }

        try runProbe(selected, dependencies: dependencies)
        try Task.checkCancellation()

        let bookmark: Data
        do {
            bookmark = try dependencies.bookmarkCreator(selected)
        } catch {
            throw validationError(
                stage: .bookmarkCreation,
                url: selected,
                reason: forgePlayTechnicalErrorSummary(error)
            )
        }
        try Task.checkCancellation()

        let resolved: SecurityScopedBookmarkResolvedURL
        do {
            resolved = try dependencies.bookmarkResolver(bookmark)
        } catch {
            throw validationError(
                stage: .bookmarkResolution,
                url: selected,
                reason: forgePlayTechnicalErrorSummary(error)
            )
        }

        let authorizationURL = resolved.url.standardizedFileURL
        let didStartResolvedScope = dependencies.securityScopeStarter(authorizationURL)
        guard didStartResolvedScope || !requiresSecurityScope else {
            throw validationError(
                stage: .securityScope,
                url: authorizationURL,
                reason: "restored folder security-scoped access could not be started"
            )
        }
        defer {
            if didStartResolvedScope {
                dependencies.securityScopeStopper(authorizationURL)
            }
        }

        let resolvedTarget = isURL(selected, containedBy: authorizationURL)
            ? selected
            : authorizationURL
        try runProbe(resolvedTarget, dependencies: dependencies)
        try Task.checkCancellation()

        return SteamStorageValidatedSelection(
            root: selected,
            bookmark: bookmark,
            resolvedURL: authorizationURL
        )
    }

    private nonisolated static func diagnoseSynchronously(
        _ snapshot: SteamStorageMountSnapshot,
        requiresSecurityScope: Bool,
        dependencies: Dependencies
    ) throws -> SteamStorageHealthReport {
        try Task.checkCancellation()
        let savedURL = URL(fileURLWithPath: snapshot.path, isDirectory: true).standardizedFileURL
        guard let bookmark = snapshot.bookmark, !bookmark.isEmpty else {
            return SteamStorageHealthReport(
                mountID: snapshot.id,
                savedPath: savedURL.path,
                resolvedPath: nil,
                status: .reconnectRequired,
                failedStage: .bookmarkResolution,
                bookmarkIsStale: false,
                technicalDetail: "security-scoped bookmark is missing"
            )
        }

        let resolved: SecurityScopedBookmarkResolvedURL
        do {
            resolved = try dependencies.bookmarkResolver(bookmark)
        } catch {
            return SteamStorageHealthReport(
                mountID: snapshot.id,
                savedPath: savedURL.path,
                resolvedPath: nil,
                status: .reconnectRequired,
                failedStage: .bookmarkResolution,
                bookmarkIsStale: false,
                technicalDetail: forgePlayTechnicalErrorSummary(error)
            )
        }
        try Task.checkCancellation()

        let authorizationURL = resolved.url.standardizedFileURL
        let didStartScope = dependencies.securityScopeStarter(authorizationURL)
        guard didStartScope || !requiresSecurityScope else {
            return SteamStorageHealthReport(
                mountID: snapshot.id,
                savedPath: savedURL.path,
                resolvedPath: authorizationURL.path,
                status: .reconnectRequired,
                failedStage: .securityScope,
                bookmarkIsStale: resolved.isStale,
                technicalDetail: "security-scoped resource access could not be started"
            )
        }
        defer {
            if didStartScope {
                dependencies.securityScopeStopper(authorizationURL)
            }
        }

        let resolvedTarget = isURL(savedURL, containedBy: authorizationURL)
            ? savedURL
            : authorizationURL
        do {
            try runProbe(resolvedTarget, dependencies: dependencies)
        } catch let error as SteamStorageAccessValidationError {
            return SteamStorageHealthReport(
                mountID: snapshot.id,
                savedPath: savedURL.path,
                resolvedPath: resolvedTarget.path,
                status: .unavailable,
                failedStage: error.stage,
                bookmarkIsStale: resolved.isStale,
                technicalDetail: error.reason
            )
        }
        try Task.checkCancellation()

        let pathChanged = resolvedTarget.path != savedURL.path
        return SteamStorageHealthReport(
            mountID: snapshot.id,
            savedPath: savedURL.path,
            resolvedPath: resolvedTarget.path,
            status: resolved.isStale || pathChanged ? .degraded : .healthy,
            failedStage: resolved.isStale || pathChanged ? .bookmarkRefresh : nil,
            bookmarkIsStale: resolved.isStale,
            technicalDetail: pathChanged ? "bookmark resolved to a different storage path" : nil
        )
    }

    private nonisolated static func runProbe(
        _ url: URL,
        dependencies: Dependencies
    ) throws {
        do {
            try dependencies.directoryProbe(url)
        } catch let error as SteamStorageAccessProbeError {
            throw SteamStorageAccessValidationError(
                stage: error.stage,
                path: error.path,
                reason: error.reason
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw validationError(
                stage: .directoryValidation,
                url: url,
                reason: forgePlayTechnicalErrorSummary(error)
            )
        }
    }

    private nonisolated static func validationError(
        stage: SteamStorageAccessStage,
        url: URL,
        reason: String
    ) -> SteamStorageAccessValidationError {
        SteamStorageAccessValidationError(stage: stage, path: url.path, reason: reason)
    }

    private nonisolated static func isURL(_ candidate: URL, containedBy root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}

enum SteamStorageDirectoryProbe {
    nonisolated static func verify(
        at directoryURL: URL,
        probeFileName: String = ".forgeplay-storage-probe-\(UUID().uuidString).tmp"
    ) throws {
        let directory = directoryURL.standardizedFileURL
        try Task.checkCancellation()
        guard isSafeProbeFileName(probeFileName) else {
            throw SteamStorageAccessProbeError(
                stage: .temporaryFileWrite,
                path: directory.path,
                reason: "probe file name must be a ForgePlay-owned leaf name"
            )
        }

        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw probeError(
                stage: .directoryValidation,
                url: directory,
                operation: "open directory",
                code: errno
            )
        }
        defer { Darwin.close(directoryDescriptor) }

        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0 else {
            throw probeError(
                stage: .directoryValidation,
                url: directory,
                operation: "inspect directory",
                code: errno
            )
        }
        guard (directoryStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw SteamStorageAccessProbeError(
                stage: .directoryValidation,
                path: directory.path,
                reason: "selected path is not a non-symlink directory"
            )
        }
        try listDirectory(descriptor: directoryDescriptor, url: directory)
        try Task.checkCancellation()

        let payload = Array("ForgePlay storage access probe\n".utf8)
        let fileDescriptor = probeFileName.withCString { fileName in
            Darwin.openat(
                directoryDescriptor,
                fileName,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard fileDescriptor >= 0 else {
            throw probeError(
                stage: .temporaryFileWrite,
                url: directory,
                operation: "create probe file",
                code: errno
            )
        }

        var operationError: Error?
        do {
            try writeAll(payload, to: fileDescriptor, directory: directory)
            try Task.checkCancellation()
            try readAndVerify(payload, from: fileDescriptor, directory: directory)
            try Task.checkCancellation()
        } catch {
            operationError = error
        }

        let closeResult = Darwin.close(fileDescriptor)
        let closeErrorCode = errno
        let unlinkResult = probeFileName.withCString { fileName in
            Darwin.unlinkat(directoryDescriptor, fileName, 0)
        }
        if unlinkResult != 0 {
            let cleanupCode = errno
            let originalReason = operationError.map { "; original failure: \(forgePlayTechnicalErrorSummary($0))" } ?? ""
            throw SteamStorageAccessProbeError(
                stage: .temporaryFileDeletion,
                path: directory.path,
                reason: "delete probe file failed: \(posixReason(cleanupCode))\(originalReason)"
            )
        }
        if closeResult != 0, operationError == nil {
            operationError = SteamStorageAccessProbeError(
                stage: .temporaryFileRead,
                path: directory.path,
                reason: "close probe file failed: \(posixReason(closeErrorCode))"
            )
        }
        if let operationError {
            throw operationError
        }
    }

    private nonisolated static func listDirectory(descriptor: Int32, url: URL) throws {
        let duplicatedDescriptor = Darwin.dup(descriptor)
        guard duplicatedDescriptor >= 0 else {
            throw probeError(
                stage: .directoryListing,
                url: url,
                operation: "duplicate directory descriptor",
                code: errno
            )
        }
        guard let directoryStream = fdopendir(duplicatedDescriptor) else {
            let code = errno
            Darwin.close(duplicatedDescriptor)
            throw probeError(
                stage: .directoryListing,
                url: url,
                operation: "open directory stream",
                code: code
            )
        }
        defer { closedir(directoryStream) }

        while true {
            errno = 0
            if readdir(directoryStream) != nil {
                break
            }
            if errno == EINTR {
                continue
            }
            guard errno == 0 else {
                throw probeError(
                    stage: .directoryListing,
                    url: url,
                    operation: "read directory entries",
                    code: errno
                )
            }
            break
        }
    }

    private nonisolated static func writeAll(
        _ payload: [UInt8],
        to descriptor: Int32,
        directory: URL
    ) throws {
        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw probeError(
                        stage: .temporaryFileWrite,
                        url: directory,
                        operation: "write probe file",
                        code: written == 0 ? EIO : errno
                    )
                }
                offset += written
            }
        }
    }

    private nonisolated static func readAndVerify(
        _ expected: [UInt8],
        from descriptor: Int32,
        directory: URL
    ) throws {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw probeError(
                stage: .temporaryFileRead,
                url: directory,
                operation: "rewind probe file",
                code: errno
            )
        }

        var received = [UInt8](repeating: 0, count: expected.count)
        var offset = 0
        while offset < received.count {
            let count = received.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(
                    descriptor,
                    rawBuffer.baseAddress?.advanced(by: offset),
                    rawBuffer.count - offset
                )
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                throw probeError(
                    stage: .temporaryFileRead,
                    url: directory,
                    operation: "read probe file",
                    code: count == 0 ? EIO : errno
                )
            }
            offset += count
        }
        guard received == expected else {
            throw SteamStorageAccessProbeError(
                stage: .temporaryFileRead,
                path: directory.path,
                reason: "probe file read-back did not match written bytes"
            )
        }
    }

    private nonisolated static func isSafeProbeFileName(_ name: String) -> Bool {
        name.hasPrefix(".forgeplay-storage-probe-") &&
            name.hasSuffix(".tmp") &&
            !name.contains("/") &&
            !name.contains("\0")
    }

    private nonisolated static func probeError(
        stage: SteamStorageAccessStage,
        url: URL,
        operation: String,
        code: Int32
    ) -> SteamStorageAccessProbeError {
        SteamStorageAccessProbeError(
            stage: stage,
            path: url.path,
            reason: "\(operation) failed: \(posixReason(code))"
        )
    }

    private nonisolated static func posixReason(_ code: Int32) -> String {
        guard let message = strerror(code) else { return "POSIX error \(code)" }
        return "\(String(cString: message)) (errno \(code))"
    }
}
