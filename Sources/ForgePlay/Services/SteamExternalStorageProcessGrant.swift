import CryptoKit
import Darwin
import Foundation

struct SteamExternalStorageProcessGrant: Hashable, Sendable {
    static let manifestFileEnvironmentKey =
        "FORGEPLAY_EXTERNAL_STORAGE_GRANT_FILE"
    static let manifestSHA256EnvironmentKey =
        "FORGEPLAY_EXTERNAL_STORAGE_GRANT_SHA256"
    static let runIdentifierEnvironmentKey =
        "FORGEPLAY_EXTERNAL_STORAGE_GRANT_RUN_ID"
    static let bridgeEnvironmentKey =
        "FORGEPLAY_EXTERNAL_STORAGE_BRIDGE"

    static let environmentKeys: Set<String> = [
        manifestFileEnvironmentKey,
        manifestSHA256EnvironmentKey,
        runIdentifierEnvironmentKey,
        bridgeEnvironmentKey
    ]

    let manifestURL: URL
    let manifestSHA256: String
    let runIdentifier: String
    let bridgeURL: URL

    var environmentOverrides: [String: String] {
        [
            Self.manifestFileEnvironmentKey: manifestURL.path,
            Self.manifestSHA256EnvironmentKey: manifestSHA256,
            Self.runIdentifierEnvironmentKey: runIdentifier,
            Self.bridgeEnvironmentKey: bridgeURL.path
        ]
    }

    static func removingEnvironment(
        from environment: [String: String]
    ) -> [String: String] {
        environment.filter { !environmentKeys.contains($0.key) }
    }
}

enum SteamExternalStorageProcessGrantError:
    LocalizedError,
    ForgePlayTechnicalDescribingError
{
    case invalidRunIdentifier(String)
    case externalStorageRootRequired
    case tooManyRoots(Int)
    case applicationGroupUnavailable
    case bridgeUnavailable(URL?)
    case invalidExternalStorageRoot(URL, String)
    case bookmarkCreationFailed(URL, String)
    case manifestTooLarge(Int)
    case unsafeGrantDirectory(URL)
    case unsafeGrantFile(URL)
    case grantPersistenceFailed(URL, String)
    case staleGrantCleanupFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .invalidRunIdentifier:
            "외장 저장소 권한 실행 식별자가 올바르지 않습니다."
        case .externalStorageRootRequired:
            "외장 저장소 권한을 준비할 위치가 없습니다."
        case .tooManyRoots(let count):
            "한 번에 연결할 수 있는 외장 저장소 위치 수를 초과했습니다: \(count)"
        case .applicationGroupUnavailable:
            "외장 저장소 권한을 전달할 App Group 저장소를 사용할 수 없습니다."
        case .bridgeUnavailable:
            "외장 저장소 권한 전달 모듈이 앱에 포함되어 있지 않습니다."
        case .invalidExternalStorageRoot(let url, _):
            "외장 저장소 위치를 안전하게 확인할 수 없습니다: \(url.path)"
        case .bookmarkCreationFailed(let url, _):
            "외장 저장소 접근 권한을 실행 프로세스용으로 준비하지 못했습니다: \(url.path)"
        case .manifestTooLarge:
            "외장 저장소 권한 정보가 허용 크기를 초과했습니다."
        case .unsafeGrantDirectory(let url):
            "외장 저장소 권한 저장 위치가 안전하지 않습니다: \(url.path)"
        case .unsafeGrantFile(let url):
            "외장 저장소 권한 파일이 안전하지 않습니다: \(url.path)"
        case .grantPersistenceFailed(let url, _):
            "외장 저장소 권한 파일을 검증하여 저장하지 못했습니다: \(url.path)"
        case .staleGrantCleanupFailed(let url, _):
            "이전 외장 저장소 권한 파일을 안전하게 정리하지 못했습니다: \(url.path)"
        }
    }

    var forgePlayTechnicalDescription: String {
        switch self {
        case .invalidRunIdentifier(let value):
            "invalid external-storage grant run identifier: \(value)"
        case .externalStorageRootRequired:
            "external-storage grant requires at least one root"
        case .tooManyRoots(let count):
            "external-storage grant root count exceeds limit: \(count)"
        case .applicationGroupUnavailable:
            "external-storage grant application-group container unavailable"
        case .bridgeUnavailable(let url):
            "external-storage grant bridge unavailable: \(url?.path ?? "missing private Frameworks directory")"
        case .invalidExternalStorageRoot(let url, let reason):
            "invalid external-storage grant root: \(url.path); \(reason)"
        case .bookmarkCreationFailed(let url, let reason):
            "implicit bookmark creation failed: \(url.path); \(reason)"
        case .manifestTooLarge(let byteCount):
            "external-storage grant manifest exceeds 524288 bytes: \(byteCount)"
        case .unsafeGrantDirectory(let url):
            "unsafe external-storage grant directory: \(url.path)"
        case .unsafeGrantFile(let url):
            "unsafe external-storage grant file: \(url.path)"
        case .grantPersistenceFailed(let url, let reason):
            "external-storage grant persistence failed: \(url.path); \(reason)"
        case .staleGrantCleanupFailed(let url, let reason):
            "external-storage stale grant cleanup failed: \(url.path); \(reason)"
        }
    }
}

struct SteamExternalStorageProcessGrantPublisher {
    typealias ApplicationGroupContainerURLProvider = () -> URL?
    typealias BridgeURLProvider = () -> URL?
    typealias BookmarkDataProvider = (URL) throws -> Data
    typealias DateProvider = () -> Date

    static let schemaVersion = 1
    static let producer = "forgeplay-external-storage-grant"
    static let maximumRootCount = 32
    static let maximumManifestBytes = 512 * 1_024

    private static let grantDirectoryComponent = "ExternalStorageGrants"
    private static let staleGrantAge: TimeInterval = 90 * 24 * 60 * 60
    private static let staleTemporaryFileAge: TimeInterval = 24 * 60 * 60
    private static let maximumCleanupRemovals = 8
    static let maximumRetainedGrantManifests = 32
    private static let maximumGrantDirectoryEntries = 1_024
    private static let maximumGrantDirectoryScanEntries = 4_096

    private struct Manifest: Codable {
        let schemaVersion: Int
        let producer: String
        let runIdentifier: String
        let createdAtUnixMilliseconds: Int64
        let entries: [Entry]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case producer
            case runIdentifier = "run_identifier"
            case createdAtUnixMilliseconds = "created_at_unix_milliseconds"
            case entries
        }
    }

    private struct Entry: Codable {
        let canonicalPath: String
        let bookmarkBase64: String

        enum CodingKeys: String, CodingKey {
            case canonicalPath = "canonical_path"
            case bookmarkBase64 = "bookmark_base64"
        }
    }

    private let fileManager: FileManager
    private let applicationGroupContainerURLProvider:
        ApplicationGroupContainerURLProvider
    private let bridgeURLProvider: BridgeURLProvider
    private let bookmarkDataProvider: BookmarkDataProvider
    private let dateProvider: DateProvider

    init() {
        fileManager = .default
        applicationGroupContainerURLProvider = {
            guard let identifier =
                ForgePlaySandboxPolicy.primaryApplicationGroupIdentifier else {
                return nil
            }
            return FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: identifier
            )
        }
        bridgeURLProvider = {
            Bundle.main.privateFrameworksURL?.appending(
                path: "ForgePlayExternalStorageAccess.dylib",
                directoryHint: .notDirectory
            )
        }
        bookmarkDataProvider = { url in
            // An implicit bookmark intentionally omits `.withSecurityScope`.
            // Resolving it in another sandboxed process activates the dynamic
            // extension that the user granted to this application.
            try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        dateProvider = Date.init
    }

    init(
        fileManager: FileManager,
        applicationGroupContainerURLProvider:
            @escaping ApplicationGroupContainerURLProvider,
        bridgeURLProvider: @escaping BridgeURLProvider,
        bookmarkDataProvider: @escaping BookmarkDataProvider,
        dateProvider: @escaping DateProvider = Date.init
    ) {
        self.fileManager = fileManager
        self.applicationGroupContainerURLProvider =
            applicationGroupContainerURLProvider
        self.bridgeURLProvider = bridgeURLProvider
        self.bookmarkDataProvider = bookmarkDataProvider
        self.dateProvider = dateProvider
    }

    func publish(
        roots: [URL],
        prefix: URL,
        runIdentifier: String
    ) throws -> SteamExternalStorageProcessGrant {
        guard let parsedRunIdentifier = UUID(uuidString: runIdentifier) else {
            throw SteamExternalStorageProcessGrantError.invalidRunIdentifier(
                runIdentifier
            )
        }
        let normalizedRunIdentifier =
            parsedRunIdentifier.uuidString.lowercased()
        guard !roots.isEmpty else {
            throw SteamExternalStorageProcessGrantError
                .externalStorageRootRequired
        }
        let canonicalRoots = try canonicalExternalStorageRoots(roots)
        guard canonicalRoots.count <= Self.maximumRootCount else {
            throw SteamExternalStorageProcessGrantError.tooManyRoots(
                canonicalRoots.count
            )
        }
        guard let applicationGroupContainer =
            applicationGroupContainerURLProvider()?.standardizedFileURL else {
            throw SteamExternalStorageProcessGrantError
                .applicationGroupUnavailable
        }
        let candidateBridgeURL = bridgeURLProvider()?.standardizedFileURL
        guard let bridgeURL = candidateBridgeURL,
              FileSystemItemPolicy.isRegularNonSymlinkFile(
                bridgeURL,
                fileManager: fileManager
              ) else {
            throw SteamExternalStorageProcessGrantError.bridgeUnavailable(
                candidateBridgeURL
            )
        }

        let grantDirectory = try prepareGrantDirectory(
            in: applicationGroupContainer,
            prefix: prefix
        )
        let manifestURL = grantDirectory.appending(
            path: "\(normalizedRunIdentifier).json",
            directoryHint: .notDirectory
        )
        try cleanupStaleGrants(
            in: grantDirectory,
            preserving: manifestURL,
            now: dateProvider()
        )

        let entries = try canonicalRoots.map { root -> Entry in
            do {
                let bookmark = try bookmarkDataProvider(root)
                return Entry(
                    canonicalPath: root.path,
                    bookmarkBase64: bookmark.base64EncodedString()
                )
            } catch {
                throw SteamExternalStorageProcessGrantError
                    .bookmarkCreationFailed(
                        root,
                        forgePlayTechnicalErrorSummary(error)
                    )
            }
        }
        let now = dateProvider()
        let manifest = Manifest(
            schemaVersion: Self.schemaVersion,
            producer: Self.producer,
            runIdentifier: normalizedRunIdentifier,
            createdAtUnixMilliseconds: Int64(
                (now.timeIntervalSince1970 * 1_000).rounded(.down)
            ),
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)
        guard manifestData.count <= Self.maximumManifestBytes else {
            throw SteamExternalStorageProcessGrantError.manifestTooLarge(
                manifestData.count
            )
        }
        try writeManifestAtomically(
            manifestData,
            to: manifestURL,
            in: grantDirectory
        )
        let persistedData = try verifiedManifestData(
            at: manifestURL,
            trustedDirectory: grantDirectory
        )
        guard persistedData == manifestData else {
            throw SteamExternalStorageProcessGrantError
                .grantPersistenceFailed(
                    manifestURL,
                    "atomic-write readback did not match encoded payload"
                )
        }
        let digest = Self.sha256Hex(persistedData)

        return SteamExternalStorageProcessGrant(
            manifestURL: manifestURL,
            manifestSHA256: digest,
            runIdentifier: normalizedRunIdentifier,
            bridgeURL: bridgeURL
        )
    }

    private func canonicalExternalStorageRoots(
        _ roots: [URL]
    ) throws -> [URL] {
        guard roots.count <= Self.maximumRootCount else {
            throw SteamExternalStorageProcessGrantError.tooManyRoots(
                roots.count
            )
        }
        var seenPaths = Set<String>()
        var result: [URL] = []
        for root in roots {
            guard root.isFileURL else {
                throw SteamExternalStorageProcessGrantError
                    .invalidExternalStorageRoot(root, "URL is not a file URL")
            }
            let canonical = root
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            do {
                try FileSystemItemPolicy.requireNonSymlinkDirectory(
                    canonical,
                    fileManager: fileManager
                )
            } catch {
                throw SteamExternalStorageProcessGrantError
                    .invalidExternalStorageRoot(
                        root,
                        forgePlayTechnicalErrorSummary(error)
                    )
            }
            if seenPaths.insert(canonical.path).inserted {
                result.append(canonical)
            }
        }
        return result
    }

    private func prepareGrantDirectory(
        in applicationGroupContainer: URL,
        prefix: URL
    ) throws -> URL {
        let grantsRoot = applicationGroupContainer
            .appending(
                path: "Library/Application Support/ForgePlay",
                directoryHint: .isDirectory
            )
            .appending(
                path: Self.grantDirectoryComponent,
                directoryHint: .isDirectory
            )
        let canonicalPrefixPath = prefix
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let prefixDigest = Self.sha256Hex(
            Data("prefix=\(canonicalPrefixPath)".utf8)
        )
        let grantDirectory = grantsRoot.appending(
            path: prefixDigest,
            directoryHint: .isDirectory
        )
        do {
            try FileSystemItemPolicy.prepareOwnedDirectoryTree(
                grantDirectory,
                trustedAncestor: applicationGroupContainer,
                privateTailComponentCount: 2
            )
        } catch {
            throw SteamExternalStorageProcessGrantError
                .grantPersistenceFailed(
                    grantDirectory,
                    forgePlayTechnicalErrorSummary(error)
                )
        }
        guard FileSystemItemPolicy.isNonSymlinkDirectory(
            grantsRoot,
            fileManager: fileManager
        ),
        FileSystemItemPolicy.isNonSymlinkDirectory(
            grantDirectory,
            fileManager: fileManager
        ),
        Self.hasOwnerOnlyPermissions(
            at: grantsRoot,
            expectedType: S_IFDIR,
            expectedPermissions: S_IRWXU
        ),
        Self.hasOwnerOnlyPermissions(
            at: grantDirectory,
            expectedType: S_IFDIR,
            expectedPermissions: S_IRWXU
        ) else {
            throw SteamExternalStorageProcessGrantError
                .unsafeGrantDirectory(grantDirectory)
        }
        return grantDirectory
    }

    private func writeManifestAtomically(
        _ data: Data,
        to destination: URL,
        in trustedDirectory: URL
    ) throws {
        guard destination.deletingLastPathComponent().standardizedFileURL ==
                trustedDirectory.standardizedFileURL,
              !fileManager.fileExists(atPath: destination.path) else {
            throw SteamExternalStorageProcessGrantError
                .unsafeGrantFile(destination)
        }
        let temporary = trustedDirectory.appending(
            path: ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).tmp",
            directoryHint: .notDirectory
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SteamExternalStorageProcessGrantError
                .grantPersistenceFailed(
                    temporary,
                    String(cString: strerror(errno))
                )
        }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary {
                try? fileManager.removeItem(at: temporary)
            }
        }
        do {
            guard fchmod(
                descriptor,
                S_IRUSR | S_IWUSR
            ) == 0 else {
                throw POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                )
            }
            try Self.writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard Self.hasOwnerOnlyPermissions(
                descriptor: descriptor,
                expectedType: S_IFREG,
                expectedPermissions: S_IRUSR | S_IWUSR
            ) else {
                throw SteamExternalStorageProcessGrantError
                    .unsafeGrantFile(temporary)
            }
            try fileManager.moveItem(at: temporary, to: destination)
            shouldRemoveTemporary = false
        } catch let error as SteamExternalStorageProcessGrantError {
            throw error
        } catch {
            throw SteamExternalStorageProcessGrantError
                .grantPersistenceFailed(
                    destination,
                    forgePlayTechnicalErrorSummary(error)
                )
        }
    }

    private func verifiedManifestData(
        at manifestURL: URL,
        trustedDirectory: URL
    ) throws -> Data {
        guard manifestURL.deletingLastPathComponent().standardizedFileURL ==
              trustedDirectory.standardizedFileURL else {
            throw SteamExternalStorageProcessGrantError
                .unsafeGrantFile(manifestURL)
        }
        let descriptor = open(
            manifestURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SteamExternalStorageProcessGrantError
                .grantPersistenceFailed(
                    manifestURL,
                    String(cString: strerror(errno))
                )
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              Self.hasOwnerOnlyPermissions(
                status: status,
                expectedType: S_IFREG,
                expectedPermissions: S_IRUSR | S_IWUSR
              ),
              status.st_size >= 0,
              status.st_size <= off_t(Self.maximumManifestBytes) else {
            throw SteamExternalStorageProcessGrantError
                .unsafeGrantFile(manifestURL)
        }
        do {
            return try Self.readAll(
                from: descriptor,
                maximumByteCount: Self.maximumManifestBytes
            )
        } catch {
            throw SteamExternalStorageProcessGrantError
                .grantPersistenceFailed(
                    manifestURL,
                    forgePlayTechnicalErrorSummary(error)
                )
        }
    }

    private static func readAll(
        from descriptor: Int32,
        maximumByteCount: Int
    ) throws -> Data {
        var data = Data()
        data.reserveCapacity(min(maximumByteCount, 16 * 1_024))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(
                    descriptor,
                    rawBuffer.baseAddress,
                    rawBuffer.count
                )
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= maximumByteCount else {
                    throw SteamExternalStorageProcessGrantError
                        .manifestTooLarge(data.count)
                }
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                throw POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                )
            }
        }
    }

    private func cleanupStaleGrants(
        in directory: URL,
        preserving currentManifest: URL,
        now: Date
    ) throws {
        let candidates: [URL]
        do {
            candidates = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ],
                options: []
            )
        } catch {
            throw SteamExternalStorageProcessGrantError
                .staleGrantCleanupFailed(
                    directory,
                    forgePlayTechnicalErrorSummary(error)
                )
        }
        guard candidates.count <=
                Self.maximumGrantDirectoryScanEntries else {
            throw SteamExternalStorageProcessGrantError
                .staleGrantCleanupFailed(
                    directory,
                    "grant directory scan limit exceeded: \(candidates.count) entries"
                )
        }
        let existingGrants = candidates.compactMap {
            candidate -> (url: URL, modifiedAt: Date)? in
            guard candidate.pathExtension == "json",
                  UUID(uuidString: candidate.deletingPathExtension()
                    .lastPathComponent) != nil,
                  candidate.standardizedFileURL !=
                    currentManifest.standardizedFileURL else {
                return nil
            }
            guard FileSystemItemPolicy.isRegularNonSymlinkFile(
                candidate,
                fileManager: fileManager
            ),
                  let values = try? candidate.resourceValues(
                    forKeys: [
                        .contentModificationDateKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey
                    ]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                return nil
            }
            return (
                candidate,
                values.contentModificationDate ?? .distantFuture
            )
        }
        let newestExistingGrant = existingGrants.max {
            $0.modifiedAt < $1.modifiedAt
        }?.url.standardizedFileURL
        let sortedExistingGrants = existingGrants.sorted {
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt < $1.modifiedAt
            }
            return $0.url.path < $1.url.path
        }
        // A new manifest is written after this cleanup. Keep a bounded recent
        // history with one slot reserved for that new file. Steam launch shuts
        // the prefix down before publishing a replacement grant, while the
        // recent tail also protects an in-flight retry from eager deletion.
        let retainedBeforeCurrent = max(
            1,
            Self.maximumRetainedGrantManifests - 1
        )
        let excessGrantCount = max(
            0,
            sortedExistingGrants.count - retainedBeforeCurrent
        )
        var grantRemovalURLs = Array(
            sortedExistingGrants
                .prefix(excessGrantCount)
                .map(\.url)
        )
        var scheduledGrantPaths = Set(
            grantRemovalURLs.map { $0.standardizedFileURL.path }
        )
        let staleCutoff = now.addingTimeInterval(-Self.staleGrantAge)
        let stale = existingGrants
            .filter {
                $0.modifiedAt < staleCutoff &&
                    $0.url.standardizedFileURL != newestExistingGrant &&
                    !scheduledGrantPaths.contains(
                        $0.url.standardizedFileURL.path
                    )
            }
            .sorted { $0.modifiedAt < $1.modifiedAt }
            .prefix(Self.maximumCleanupRemovals)
        for candidate in stale {
            let path = candidate.url.standardizedFileURL.path
            if scheduledGrantPaths.insert(path).inserted {
                grantRemovalURLs.append(candidate.url)
            }
        }
        var removedEntryCount = 0
        for candidate in grantRemovalURLs {
            do {
                try fileManager.removeItem(at: candidate)
                removedEntryCount += 1
            } catch {
                throw SteamExternalStorageProcessGrantError
                    .staleGrantCleanupFailed(
                        candidate,
                        forgePlayTechnicalErrorSummary(error)
                    )
            }
        }
        let remainingRemovalCount =
            Self.maximumCleanupRemovals - stale.count
        if remainingRemovalCount > 0 {
            let temporaryCutoff = now.addingTimeInterval(
                -Self.staleTemporaryFileAge
            )
            let staleTemporaryFiles = candidates.compactMap {
                candidate -> (url: URL, modifiedAt: Date)? in
                let name = candidate.lastPathComponent
                guard name.hasPrefix("."),
                      name.hasSuffix(".tmp"),
                      FileSystemItemPolicy.isRegularNonSymlinkFile(
                        candidate,
                        fileManager: fileManager
                      ),
                      let values = try? candidate.resourceValues(
                        forKeys: [
                            .contentModificationDateKey,
                            .isRegularFileKey,
                            .isSymbolicLinkKey
                        ]
                      ),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt < temporaryCutoff else {
                    return nil
                }
                return (candidate, modifiedAt)
            }
            .sorted { $0.modifiedAt < $1.modifiedAt }
            .prefix(remainingRemovalCount)
            for candidate in staleTemporaryFiles {
                do {
                    try fileManager.removeItem(at: candidate.url)
                    removedEntryCount += 1
                } catch {
                    throw SteamExternalStorageProcessGrantError
                        .staleGrantCleanupFailed(
                            candidate.url,
                            forgePlayTechnicalErrorSummary(error)
                        )
                }
            }
        }
        let remainingEntryCount = candidates.count - removedEntryCount
        guard remainingEntryCount <
                Self.maximumGrantDirectoryEntries else {
            throw SteamExternalStorageProcessGrantError
                .staleGrantCleanupFailed(
                    directory,
                    "grant directory has no safe capacity for a new manifest: \(remainingEntryCount) entries"
                )
        }
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
                }
                guard written > 0 else {
                    throw POSIXError(.EIO)
                }
                offset += written
            }
        }
    }

    private static func hasOwnerOnlyPermissions(
        at url: URL,
        expectedType: mode_t,
        expectedPermissions: mode_t
    ) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return false }
        return hasOwnerOnlyPermissions(
            status: status,
            expectedType: expectedType,
            expectedPermissions: expectedPermissions
        )
    }

    private static func hasOwnerOnlyPermissions(
        descriptor: Int32,
        expectedType: mode_t,
        expectedPermissions: mode_t
    ) -> Bool {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return false }
        return hasOwnerOnlyPermissions(
            status: status,
            expectedType: expectedType,
            expectedPermissions: expectedPermissions
        )
    }

    private static func hasOwnerOnlyPermissions(
        status: stat,
        expectedType: mode_t,
        expectedPermissions: mode_t
    ) -> Bool {
        (status.st_mode & S_IFMT) == expectedType &&
            (status.st_mode & mode_t(0o777)) == expectedPermissions &&
            status.st_uid == geteuid() &&
            (expectedType != S_IFREG || status.st_nlink == 1)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
