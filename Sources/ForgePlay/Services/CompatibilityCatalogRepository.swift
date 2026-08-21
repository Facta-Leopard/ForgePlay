import Darwin
import Foundation

enum CompatibilityCatalogOrigin: String, Equatable, Sendable {
    case bundled
    case cached
    case refreshed
}

struct LoadedCompatibilityCatalog: Sendable {
    let snapshot: CompatibilityCatalogSnapshot
    let origin: CompatibilityCatalogOrigin
    let cacheWarningKey: String?
}

enum CompatibilityCatalogRepositoryError: LocalizedError, Equatable {
    case officialEndpointUnavailable
    case invalidResolvedURL
    case invalidHTTPStatus(Int)
    case responseTooLarge(Int, Int)
    case rollback(current: String, received: String)
    case revisionConflict(updatedAt: String)
    case cacheUnavailable
    case cacheCommitFailed
    case refreshInProgress

    var errorDescription: String? {
        switch self {
        case .officialEndpointUnavailable:
            "공식 공개 호환성 목록 주소를 확인할 수 없습니다."
        case .invalidResolvedURL:
            "공개 호환성 목록이 허용되지 않은 주소로 이동하여 갱신을 중단했습니다."
        case .invalidHTTPStatus(let statusCode):
            "공개 호환성 목록 서버 응답이 올바르지 않습니다: HTTP \(statusCode)"
        case .responseTooLarge(let byteCount, let limit):
            "공개 호환성 목록 응답이 너무 큽니다: \(byteCount) bytes / limit \(limit) bytes"
        case .rollback(let current, let received):
            "현재 목록보다 오래된 공개 호환성 목록은 적용하지 않습니다: current \(current), received \(received)"
        case .revisionConflict(let updatedAt):
            "같은 기준일의 공개 호환성 목록 내용이 달라 갱신을 적용하지 않았습니다: \(updatedAt)"
        case .cacheUnavailable:
            "공개 호환성 목록 캐시 위치를 안전하게 준비할 수 없습니다."
        case .cacheCommitFailed:
            "공개 호환성 목록 캐시를 안전하게 저장하지 못했습니다."
        case .refreshInProgress:
            "공개 호환성 목록 갱신이 이미 진행 중입니다."
        }
    }
}

enum CompatibilityCatalogRefreshResolution: Equatable {
    case installExpected
    case useExisting
}

struct CompatibilityCatalogRefreshResolver {
    static func resolve(
        expected: CompatibilityCatalogSnapshot,
        callerCurrent: CompatibilityCatalogSnapshot,
        existing: CompatibilityCatalogSnapshot?,
        sameRevisionPayload: (
            CompatibilityCatalogSnapshot,
            CompatibilityCatalogSnapshot
        ) -> Bool
    ) throws -> CompatibilityCatalogRefreshResolution {
        if let existing,
           existing.updatedAt > callerCurrent.updatedAt,
           expected.updatedAt == callerCurrent.updatedAt,
           sameRevisionPayload(expected, callerCurrent) {
            return .useExisting
        }
        let currentRevision = max(
            callerCurrent.updatedAt,
            existing?.updatedAt ?? ""
        )
        guard expected.updatedAt >= currentRevision else {
            throw CompatibilityCatalogRepositoryError.rollback(
                current: currentRevision,
                received: expected.updatedAt
            )
        }
        if expected.updatedAt == currentRevision {
            let currentSnapshots = [callerCurrent, existing]
                .compactMap { $0 }
                .filter { $0.updatedAt == currentRevision }
            guard currentSnapshots.allSatisfy({
                sameRevisionPayload($0, expected)
            }) else {
                throw CompatibilityCatalogRepositoryError.revisionConflict(
                    updatedAt: currentRevision
                )
            }
            if let existing,
               sameRevisionPayload(existing, expected) {
                return .useExisting
            }
        }
        return .installExpected
    }
}

actor CompatibilityCatalogRepository {
    static let officialEndpointURL = URL(
        string: "https://facta-leopard.github.io/ForgePlay/site-data/compatibility-games.json"
    )
    static let cacheFileName = "compatibility-games.json"

    private static let cacheLockFileName = ".compatibility-catalog.lock"
    private static let unreadableCacheWarningKey =
        "저장된 공개 호환성 목록을 사용할 수 없어 앱 포함 목록을 사용합니다."
    private static let unavailableCacheLockWarningKey =
        "저장된 공개 호환성 목록 잠금을 안전하게 사용할 수 없어 앱 포함 목록을 사용합니다."
    private static let repairedRevisionConflictWarningKey =
        "같은 기준일의 저장된 공개 호환성 목록이 앱 포함 목록과 달라 신뢰할 수 있는 앱 포함 목록으로 복구했습니다."
    private static let unrepairedRevisionConflictWarningKey =
        "같은 기준일의 저장된 공개 호환성 목록이 앱 포함 목록과 달라 앱 포함 목록을 사용하지만 저장 자료를 복구하지 못했습니다."

    private enum EqualRevisionRepairOutcome {
        case trustedBaseline(repaired: Bool)
        case cached(CompatibilityCatalogSnapshot)
    }

    private enum RefreshReconciliationOutcome {
        case refreshed(CompatibilityCatalogSnapshot)
        case cached(CompatibilityCatalogSnapshot)
    }

    private enum CacheLockAcquisitionError: Error {
        case unavailable
        case unsafeLeaf
        case timedOut
    }

    enum CacheLockEvent: Equatable, Sendable {
        case recoveryGateFlockAcquired
        case recoveryGateAcquired
        case recoveryGateContended
        case leafFlockAcquired
        case leafOpened(device: UInt64, inode: UInt64)
        case leafContended
        case criticalSectionEntered(exclusive: Bool)
        case criticalSectionExited(exclusive: Bool)
    }

    private enum CacheLockWaitStage {
        case recoveryGate
        case leaf
    }

    typealias CacheCommitCheckpoint = @Sendable (
        _ committedCacheURL: URL,
        _ displacedCacheURL: URL
    ) throws -> Void

    private let catalogService: CompatibilityCatalogService
    private let bundledSnapshotURL: URL?
    private let cacheRootURL: URL?
    private let cacheDirectoryURL: URL?
    private let endpointURL: URL?
    private let remoteSessionConfiguration: URLSessionConfiguration
    private let remoteBufferObserver: (@Sendable (Int) -> Void)?
    private let fileManager: FileManager
    private let cacheLockTimeout: Duration
    private let cacheLockRetryDelay: Duration
    private let cacheLockContentionObserver: (@Sendable () -> Void)?
    private let cacheLockEventObserver: (@Sendable (CacheLockEvent) -> Void)?
    private let cacheCommitCheckpoint: CacheCommitCheckpoint?
    private var isRefreshInProgress = false

    init(
        catalogService: CompatibilityCatalogService = CompatibilityCatalogService(),
        bundle: Bundle = .main,
        bundledSnapshotURL: URL? = nil,
        cacheRootURL: URL? = nil,
        cacheDirectoryURL: URL? = nil,
        endpointURL: URL? = CompatibilityCatalogRepository.officialEndpointURL,
        session: URLSession? = nil,
        remoteBufferObserver: (@Sendable (Int) -> Void)? = nil,
        fileManager: FileManager = .default,
        cacheLockTimeout: Duration = .seconds(2),
        cacheLockRetryDelay: Duration = .milliseconds(20),
        cacheLockContentionObserver: (@Sendable () -> Void)? = nil,
        cacheLockEventObserver: (@Sendable (CacheLockEvent) -> Void)? = nil,
        cacheCommitCheckpoint: CacheCommitCheckpoint? = nil
    ) {
        self.catalogService = catalogService
        self.bundledSnapshotURL = bundledSnapshotURL ?? bundle.url(
            forResource: "compatibility-games",
            withExtension: "json",
            subdirectory: "CompatibilityCatalog"
        ) ?? bundle.url(forResource: "compatibility-games", withExtension: "json")

        let defaultCacheRoot = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first?.standardizedFileURL
        let resolvedCacheRoot = cacheRootURL?.standardizedFileURL ?? defaultCacheRoot
        self.cacheRootURL = resolvedCacheRoot
        self.cacheDirectoryURL = cacheDirectoryURL?.standardizedFileURL ?? resolvedCacheRoot?
            .appending(path: "ForgePlay", directoryHint: .isDirectory)
            .appending(path: "CompatibilityCatalog", directoryHint: .isDirectory)
        self.endpointURL = endpointURL
        self.remoteSessionConfiguration = (session?.configuration.copy()
            as? URLSessionConfiguration) ?? Self.defaultRemoteSessionConfiguration()
        self.remoteBufferObserver = remoteBufferObserver
        self.fileManager = fileManager
        self.cacheLockTimeout = cacheLockTimeout
        self.cacheLockRetryDelay = cacheLockRetryDelay
        self.cacheLockContentionObserver = cacheLockContentionObserver
        self.cacheLockEventObserver = cacheLockEventObserver
        self.cacheCommitCheckpoint = cacheCommitCheckpoint
    }

    nonisolated static func defaultRemoteSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    nonisolated static func boundedCacheLockRetryDelay(
        configuredDelay: Duration,
        remaining: Duration
    ) -> Duration {
        min(max(configuredDelay, .zero), max(remaining, .zero))
    }

    func loadCurrent() async throws -> LoadedCompatibilityCatalog {
        try Task.checkCancellation()
        guard let bundledSnapshotURL else {
            throw CompatibilityCatalogServiceError.bundledSnapshotMissing
        }
        let bundledPayload = try catalogService.loadValidatedPayload(at: bundledSnapshotURL)
        let bundled = bundledPayload.snapshot
        try Task.checkCancellation()
        guard let cacheDirectoryURL, directoryEntryExists(cacheDirectoryURL) else {
            return LoadedCompatibilityCatalog(
                snapshot: bundled,
                origin: .bundled,
                cacheWarningKey: nil
            )
        }

        do {
            let cached = try await withCacheLock(exclusive: false) {
                try loadCacheUnderLock()
            }
            guard let cached, cached.updatedAt >= bundled.updatedAt else {
                return LoadedCompatibilityCatalog(
                    snapshot: bundled,
                    origin: .bundled,
                    cacheWarningKey: nil
                )
            }
            guard cached.updatedAt == bundled.updatedAt else {
                return LoadedCompatibilityCatalog(
                    snapshot: cached,
                    origin: .cached,
                    cacheWarningKey: nil
                )
            }
            guard !sameRevisionPayload(cached, bundled) else {
                return LoadedCompatibilityCatalog(
                    snapshot: cached,
                    origin: .cached,
                    cacheWarningKey: nil
                )
            }

            do {
                switch try await repairEqualRevisionConflict(
                    trustedPayload: bundledPayload
                ) {
                case .cached(let currentCache):
                    return LoadedCompatibilityCatalog(
                        snapshot: currentCache,
                        origin: .cached,
                        cacheWarningKey: nil
                    )
                case .trustedBaseline(let repaired):
                    return LoadedCompatibilityCatalog(
                        snapshot: bundled,
                        origin: .bundled,
                        cacheWarningKey: repaired
                            ? Self.repairedRevisionConflictWarningKey
                            : nil
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CacheLockAcquisitionError {
                throw error
            } catch {
                return LoadedCompatibilityCatalog(
                    snapshot: bundled,
                    origin: .bundled,
                    cacheWarningKey: Self.unrepairedRevisionConflictWarningKey
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is CacheLockAcquisitionError {
            return LoadedCompatibilityCatalog(
                snapshot: bundled,
                origin: .bundled,
                cacheWarningKey: Self.unavailableCacheLockWarningKey
            )
        } catch {
            return LoadedCompatibilityCatalog(
                snapshot: bundled,
                origin: .bundled,
                cacheWarningKey: Self.unreadableCacheWarningKey
            )
        }
    }

    func refresh(current: CompatibilityCatalogSnapshot) async throws -> LoadedCompatibilityCatalog {
        guard !isRefreshInProgress else {
            throw CompatibilityCatalogRepositoryError.refreshInProgress
        }
        isRefreshInProgress = true
        defer { isRefreshInProgress = false }

        guard let endpointURL else {
            throw CompatibilityCatalogRepositoryError.officialEndpointUnavailable
        }
        var request = URLRequest(url: endpointURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let downloader = CompatibilityCatalogRemoteDownloader(
            expectedURL: endpointURL,
            maximumBytes: CompatibilityCatalogService.maximumSnapshotBytes,
            bufferObserver: remoteBufferObserver
        )
        let (data, _) = try await downloader.fetch(
            request: request,
            configuration: remoteSessionConfiguration
        )
        try Task.checkCancellation()

        let refreshed = try catalogService.loadSnapshot(data: data)
        guard refreshed.updatedAt >= current.updatedAt else {
            throw CompatibilityCatalogRepositoryError.rollback(
                current: current.updatedAt,
                received: refreshed.updatedAt
            )
        }
        try Task.checkCancellation()
        switch try await reconcileRefresh(
            data,
            expectedSnapshot: refreshed,
            callerCurrent: current
        ) {
        case .cached(let latest):
            return LoadedCompatibilityCatalog(
                snapshot: latest,
                origin: .cached,
                cacheWarningKey: nil
            )
        case .refreshed(let committed):
            return LoadedCompatibilityCatalog(
                snapshot: committed,
                origin: .refreshed,
                cacheWarningKey: nil
            )
        }
    }

    private func resolvedCacheURL() -> URL? {
        cacheDirectoryURL?.appending(path: Self.cacheFileName, directoryHint: .notDirectory)
    }

    private func resolvedCacheLockURL() -> URL? {
        cacheDirectoryURL?.appending(path: Self.cacheLockFileName, directoryHint: .notDirectory)
    }

    private func requireSafeCacheReadPath(_ cacheURL: URL) throws {
        guard let cacheRootURL,
              FileSystemItemPolicy.hasOnlyNonSymlinkDirectoryComponents(
                from: cacheRootURL,
                to: cacheURL,
                fileManager: fileManager
              ) else {
            throw CompatibilityCatalogRepositoryError.cacheUnavailable
        }
    }

    private func loadCacheUnderLock() throws -> CompatibilityCatalogSnapshot? {
        guard let cacheURL = resolvedCacheURL() else {
            throw CompatibilityCatalogRepositoryError.cacheUnavailable
        }
        guard directoryEntryExists(cacheURL) else { return nil }
        try requireSafeCacheReadPath(cacheURL)
        return try catalogService.loadSnapshot(at: cacheURL)
    }

    private func reconcileRefresh(
        _ data: Data,
        expectedSnapshot: CompatibilityCatalogSnapshot,
        callerCurrent: CompatibilityCatalogSnapshot
    ) async throws -> RefreshReconciliationOutcome {
        do {
            try prepareCacheDirectory()
            return try await withCacheLock(
                exclusive: true,
                recoverUnsafeLeaf: true
            ) {
                try Task.checkCancellation()
                let previousSnapshot = try loadRepairableCacheUnderLock()
                let resolution = try CompatibilityCatalogRefreshResolver.resolve(
                    expected: expectedSnapshot,
                    callerCurrent: callerCurrent,
                    existing: previousSnapshot,
                    sameRevisionPayload: sameRevisionPayload
                )
                if resolution == .useExisting, let previousSnapshot {
                    return .cached(previousSnapshot)
                }
                try installCacheDataUnderLock(
                    data,
                    expectedSnapshot: expectedSnapshot,
                    previousSnapshot: previousSnapshot
                )
                return .refreshed(expectedSnapshot)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CacheLockAcquisitionError {
            throw mapCacheLockError(error)
        } catch let error as CompatibilityCatalogRepositoryError {
            throw error
        } catch {
            throw CompatibilityCatalogRepositoryError.cacheCommitFailed
        }
    }

    private func repairEqualRevisionConflict(
        trustedPayload: ValidatedCompatibilityCatalogPayload
    ) async throws -> EqualRevisionRepairOutcome {
        try prepareCacheDirectory()
        return try await withCacheLock(
            exclusive: true,
            recoverUnsafeLeaf: true
        ) {
            try Task.checkCancellation()
            guard let currentCache = try loadRepairableCacheUnderLock() else {
                return .trustedBaseline(repaired: false)
            }
            if currentCache.updatedAt > trustedPayload.snapshot.updatedAt {
                return .cached(currentCache)
            }
            if sameRevisionPayload(currentCache, trustedPayload.snapshot) {
                return .cached(currentCache)
            }
            try installCacheDataUnderLock(
                trustedPayload.data,
                expectedSnapshot: trustedPayload.snapshot,
                previousSnapshot: currentCache
            )
            return .trustedBaseline(repaired: true)
        }
    }

    private func loadRepairableCacheUnderLock() throws
        -> CompatibilityCatalogSnapshot?
    {
        do {
            return try loadCacheUnderLock()
        } catch {
            guard let cacheURL = resolvedCacheURL(), directoryEntryExists(cacheURL) else {
                return nil
            }
            guard Darwin.unlink(cacheURL.path) == 0 || errno == ENOENT else {
                throw CompatibilityCatalogRepositoryError.cacheCommitFailed
            }
            guard let cacheDirectoryURL else {
                throw CompatibilityCatalogRepositoryError.cacheCommitFailed
            }
            try synchronizeDirectory(at: cacheDirectoryURL)
            return nil
        }
    }

    private func prepareCacheDirectory() throws {
        guard let cacheRootURL, let cacheDirectoryURL, resolvedCacheURL() != nil else {
            throw CompatibilityCatalogRepositoryError.cacheUnavailable
        }
        let privateTailCount = cacheDirectoryURL.pathComponents.count - cacheRootURL.pathComponents.count
        guard privateTailCount > 0 else {
            throw CompatibilityCatalogRepositoryError.cacheUnavailable
        }
        try FileSystemItemPolicy.prepareOwnedDirectoryTree(
            cacheDirectoryURL,
            trustedAncestor: cacheRootURL,
            privateTailComponentCount: privateTailCount
        )
    }

    private func sameRevisionPayload(
        _ lhs: CompatibilityCatalogSnapshot,
        _ rhs: CompatibilityCatalogSnapshot
    ) -> Bool {
        guard lhs.updatedAt == rhs.updatedAt,
              let lhsHash = lhs.sourcePayloadSHA256,
              let rhsHash = rhs.sourcePayloadSHA256 else {
            return false
        }
        return lhsHash == rhsHash
    }

    private func installCacheDataUnderLock(
        _ data: Data,
        expectedSnapshot: CompatibilityCatalogSnapshot,
        previousSnapshot: CompatibilityCatalogSnapshot?
    ) throws {
        guard let cacheDirectoryURL, let cacheURL = resolvedCacheURL(),
              let expectedHash = expectedSnapshot.sourcePayloadSHA256 else {
            throw CompatibilityCatalogRepositoryError.cacheCommitFailed
        }
        let stagingURL = cacheDirectoryURL.appending(
            path: ".compatibility-games.\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )
        defer {
            try? fileManager.removeItem(at: stagingURL)
        }

        try data.write(to: stagingURL, options: [.withoutOverwriting])
        try FileSystemItemPolicy.normalizeExistingOwnedPrivateRegularFile(stagingURL)
        let stagedSnapshot = try catalogService.loadSnapshot(at: stagingURL)
        guard stagedSnapshot.sourcePayloadSHA256 == expectedHash else {
            throw CompatibilityCatalogRepositoryError.cacheCommitFailed
        }
        try synchronizeRegularFile(at: stagingURL)

        if let previousSnapshot {
            guard atomicSwap(stagingURL, cacheURL) else {
                throw CompatibilityCatalogRepositoryError.cacheCommitFailed
            }
            do {
                try cacheCommitCheckpoint?(cacheURL, stagingURL)
                try validateCommittedCache(
                    at: cacheURL,
                    expectedHash: expectedHash
                )
                try synchronizeDirectory(at: cacheDirectoryURL)
            } catch {
                guard restorePreviousCacheAfterSwap(
                    cacheURL: cacheURL,
                    displacedCacheURL: stagingURL,
                    expectedPreviousHash:
                        previousSnapshot.sourcePayloadSHA256
                ) else {
                    throw CompatibilityCatalogRepositoryError.cacheCommitFailed
                }
                throw error
            }

            guard Darwin.unlink(stagingURL.path) == 0 else {
                guard restorePreviousCacheAfterSwap(
                    cacheURL: cacheURL,
                    displacedCacheURL: stagingURL,
                    expectedPreviousHash:
                        previousSnapshot.sourcePayloadSHA256
                ) else {
                    throw CompatibilityCatalogRepositoryError.cacheCommitFailed
                }
                throw CompatibilityCatalogRepositoryError.cacheCommitFailed
            }
            try synchronizeDirectory(at: cacheDirectoryURL)
            return
        }

        guard Darwin.rename(stagingURL.path, cacheURL.path) == 0 else {
            throw CompatibilityCatalogRepositoryError.cacheCommitFailed
        }
        do {
            try validateCommittedCache(at: cacheURL, expectedHash: expectedHash)
            try synchronizeDirectory(at: cacheDirectoryURL)
        } catch {
            guard removeCacheWithoutPreviousSnapshot(cacheURL) else {
                throw CompatibilityCatalogRepositoryError.cacheCommitFailed
            }
            throw error
        }
    }

    private func atomicSwap(_ lhs: URL, _ rhs: URL) -> Bool {
        Darwin.renamex_np(lhs.path, rhs.path, UInt32(RENAME_SWAP)) == 0
    }

    private func validateCommittedCache(
        at cacheURL: URL,
        expectedHash: String
    ) throws {
        try requireSafeCacheReadPath(cacheURL)
        let committedSnapshot = try catalogService.loadSnapshot(at: cacheURL)
        guard committedSnapshot.sourcePayloadSHA256 == expectedHash else {
            throw CompatibilityCatalogRepositoryError.cacheCommitFailed
        }
    }

    private func restorePreviousCacheAfterSwap(
        cacheURL: URL,
        displacedCacheURL: URL,
        expectedPreviousHash: String?
    ) -> Bool {
        guard atomicSwap(displacedCacheURL, cacheURL) else { return false }
        guard let expectedPreviousHash else { return false }
        guard (try? catalogService.loadSnapshot(at: cacheURL).sourcePayloadSHA256) == expectedPreviousHash,
              let cacheDirectoryURL else {
            return false
        }
        do {
            try synchronizeDirectory(at: cacheDirectoryURL)
            return true
        } catch {
            return false
        }
    }

    private func removeCacheWithoutPreviousSnapshot(_ cacheURL: URL) -> Bool {
        guard Darwin.unlink(cacheURL.path) == 0 || errno == ENOENT,
              let cacheDirectoryURL else {
            return false
        }
        do {
            try synchronizeDirectory(at: cacheDirectoryURL)
            return true
        } catch {
            return false
        }
    }

    private func withCacheLock<T>(
        exclusive: Bool,
        recoverUnsafeLeaf: Bool = false,
        _ operation: () throws -> T
    ) async throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: cacheLockTimeout)
        let descriptor = try await openCacheLockUnderRecoveryGate(
            exclusive: exclusive,
            recoverUnsafeLeaf: recoverUnsafeLeaf,
            clock: clock,
            deadline: deadline
        )
        defer { Darwin.close(descriptor) }

        cacheLockEventObserver?(.criticalSectionEntered(exclusive: exclusive))
        defer {
            cacheLockEventObserver?(.criticalSectionExited(exclusive: exclusive))
            while flock(descriptor, LOCK_UN) != 0, errno == EINTR {}
        }
        return try operation()
    }

    private func openCacheLockUnderRecoveryGate(
        exclusive: Bool,
        recoverUnsafeLeaf: Bool,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> Int32 {
        try Task.checkCancellation()
        let directoryDescriptor = try verifiedCacheDirectoryDescriptor(
            requirePrivatePermissions: recoverUnsafeLeaf
        )
        defer {
            // Closing the descriptor releases the directory flock only after
            // a validated leaf descriptor has been fixed for this caller.
            Darwin.close(directoryDescriptor)
        }

        try await acquireCacheFlock(
            directoryDescriptor,
            mode: LOCK_EX,
            stage: .recoveryGate,
            clock: clock,
            deadline: deadline
        )
        cacheLockEventObserver?(.recoveryGateAcquired)
        try Task.checkCancellation()

        while true {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw CacheLockAcquisitionError.timedOut
            }

            let descriptor: Int32
            do {
                descriptor = try openValidatedCacheLock(
                    directoryDescriptor: directoryDescriptor
                )
            } catch CacheLockAcquisitionError.unsafeLeaf
                where exclusive && recoverUnsafeLeaf {
                descriptor = try resetUnsafeCacheLock(
                    directoryDescriptor: directoryDescriptor
                )
            }

            do {
                try await acquireCacheFlock(
                    descriptor,
                    mode: exclusive ? LOCK_EX : LOCK_SH,
                    stage: .leaf,
                    clock: clock,
                    deadline: deadline
                )
            } catch {
                Darwin.close(descriptor)
                throw error
            }

            var descriptorMetadata = stat()
            guard Darwin.fstat(descriptor, &descriptorMetadata) == 0,
                  isValidCacheLockMetadata(descriptorMetadata) else {
                while flock(descriptor, LOCK_UN) != 0, errno == EINTR {}
                Darwin.close(descriptor)
                throw CacheLockAcquisitionError.unavailable
            }
            cacheLockEventObserver?(.leafOpened(
                device: UInt64(truncatingIfNeeded: descriptorMetadata.st_dev),
                inode: UInt64(truncatingIfNeeded: descriptorMetadata.st_ino)
            ))

            var pathMetadata = stat()
            let currentEntryMatchesDescriptor = Darwin.fstatat(
                directoryDescriptor,
                Self.cacheLockFileName,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0 &&
                isValidCacheLockMetadata(pathMetadata) &&
                sameFileIdentity(descriptorMetadata, pathMetadata)
            if currentEntryMatchesDescriptor {
                do {
                    try Task.checkCancellation()
                    guard clock.now < deadline else {
                        throw CacheLockAcquisitionError.timedOut
                    }
                    return descriptor
                } catch {
                    while flock(descriptor, LOCK_UN) != 0, errno == EINTR {}
                    Darwin.close(descriptor)
                    throw error
                }
            }

            while flock(descriptor, LOCK_UN) != 0, errno == EINTR {}
            Darwin.close(descriptor)
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw CacheLockAcquisitionError.timedOut
            }
            await Task.yield()
        }
    }

    private func acquireCacheFlock(
        _ descriptor: Int32,
        mode: Int32,
        stage: CacheLockWaitStage,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws {
        let nonblockingMode = mode | LOCK_NB
        while true {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw CacheLockAcquisitionError.timedOut
            }
            if flock(descriptor, nonblockingMode) == 0 {
                switch stage {
                case .recoveryGate:
                    cacheLockEventObserver?(.recoveryGateFlockAcquired)
                case .leaf:
                    cacheLockEventObserver?(.leafFlockAcquired)
                }
                do {
                    try Task.checkCancellation()
                    guard clock.now < deadline else {
                        throw CacheLockAcquisitionError.timedOut
                    }
                    return
                } catch {
                    while flock(descriptor, LOCK_UN) != 0, errno == EINTR {}
                    throw error
                }
            }

            let lockError = errno
            if lockError == EINTR {
                continue
            }
            guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
                throw CacheLockAcquisitionError.unavailable
            }
            cacheLockContentionObserver?()
            switch stage {
            case .recoveryGate:
                cacheLockEventObserver?(.recoveryGateContended)
            case .leaf:
                cacheLockEventObserver?(.leafContended)
            }
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw CacheLockAcquisitionError.timedOut
            }
            let delay = Self.boundedCacheLockRetryDelay(
                configuredDelay: cacheLockRetryDelay,
                remaining: clock.now.duration(to: deadline)
            )
            if delay > .zero {
                try await Task.sleep(for: delay)
            } else {
                await Task.yield()
            }
        }
    }

    private func verifiedCacheDirectoryDescriptor(
        requirePrivatePermissions: Bool
    ) throws -> Int32 {
        guard let cacheRootURL, let cacheDirectoryURL else {
            throw CacheLockAcquisitionError.unavailable
        }
        let rootComponents = cacheRootURL.standardizedFileURL.pathComponents
        let directoryComponents = cacheDirectoryURL.standardizedFileURL
            .pathComponents
        guard directoryComponents.count > rootComponents.count,
              directoryComponents.starts(with: rootComponents) else {
            throw CacheLockAcquisitionError.unavailable
        }

        var descriptor = Darwin.open(
            cacheRootURL.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw CacheLockAcquisitionError.unavailable
        }
        guard validateDirectoryDescriptor(
            descriptor,
            requiresPrivatePermissions: false
        ) else {
            Darwin.close(descriptor)
            throw CacheLockAcquisitionError.unavailable
        }

        for component in directoryComponents.dropFirst(rootComponents.count) {
            let childDescriptor = Darwin.openat(
                descriptor,
                component,
                O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
            )
            guard childDescriptor >= 0 else {
                Darwin.close(descriptor)
                throw CacheLockAcquisitionError.unavailable
            }
            let isValid = validateDirectoryDescriptor(
                childDescriptor,
                requiresPrivatePermissions: requirePrivatePermissions
            )
            Darwin.close(descriptor)
            guard isValid else {
                Darwin.close(childDescriptor)
                throw CacheLockAcquisitionError.unavailable
            }
            descriptor = childDescriptor
        }
        return descriptor
    }

    private func validateDirectoryDescriptor(
        _ descriptor: Int32,
        requiresPrivatePermissions: Bool
    ) -> Bool {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o022 == 0 else {
            return false
        }
        return !requiresPrivatePermissions || metadata.st_mode & 0o077 == 0
    }

    private func openValidatedCacheLock(
        directoryDescriptor: Int32
    ) throws -> Int32 {
        for _ in 0..<2 {
            var pathMetadata = stat()
            if Darwin.fstatat(
                directoryDescriptor,
                Self.cacheLockFileName,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0 {
                guard isValidCacheLockMetadata(pathMetadata) else {
                    throw CacheLockAcquisitionError.unsafeLeaf
                }
                let descriptor = Darwin.openat(
                    directoryDescriptor,
                    Self.cacheLockFileName,
                    O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
                guard descriptor >= 0 else {
                    if errno == ENOENT { continue }
                    throw CacheLockAcquisitionError.unavailable
                }
                var descriptorMetadata = stat()
                let validDescriptor = Darwin.fstat(
                    descriptor,
                    &descriptorMetadata
                ) == 0 &&
                    isValidCacheLockMetadata(descriptorMetadata) &&
                    sameFileIdentity(pathMetadata, descriptorMetadata)
                guard validDescriptor else {
                    Darwin.close(descriptor)
                    continue
                }
                return descriptor
            }
            guard errno == ENOENT else {
                throw CacheLockAcquisitionError.unavailable
            }

            let descriptor = Darwin.openat(
                directoryDescriptor,
                Self.cacheLockFileName,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW |
                    O_NONBLOCK,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                if errno == EEXIST { continue }
                throw CacheLockAcquisitionError.unavailable
            }
            guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                Darwin.close(descriptor)
                throw CacheLockAcquisitionError.unavailable
            }
            var descriptorMetadata = stat()
            var installedMetadata = stat()
            let isInstalledIdentity = Darwin.fstat(
                descriptor,
                &descriptorMetadata
            ) == 0 &&
                Darwin.fstatat(
                    directoryDescriptor,
                    Self.cacheLockFileName,
                    &installedMetadata,
                    AT_SYMLINK_NOFOLLOW
                ) == 0 &&
                isValidCacheLockMetadata(descriptorMetadata) &&
                sameFileIdentity(descriptorMetadata, installedMetadata)
            guard isInstalledIdentity else {
                Darwin.close(descriptor)
                throw CacheLockAcquisitionError.unavailable
            }
            return descriptor
        }
        throw CacheLockAcquisitionError.unavailable
    }

    private func resetUnsafeCacheLock(
        directoryDescriptor: Int32
    ) throws -> Int32 {
        var metadata = stat()
        guard Darwin.fstatat(
            directoryDescriptor,
            Self.cacheLockFileName,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT {
                return try openValidatedCacheLock(
                    directoryDescriptor: directoryDescriptor
                )
            }
            throw CacheLockAcquisitionError.unavailable
        }
        guard !isValidCacheLockMetadata(metadata) else {
            return try openValidatedCacheLock(
                directoryDescriptor: directoryDescriptor
            )
        }

        let quarantineName =
            ".compatibility-catalog.lock.quarantine.\(UUID().uuidString)"
        guard Darwin.renameatx_np(
            directoryDescriptor,
            Self.cacheLockFileName,
            directoryDescriptor,
            quarantineName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw CacheLockAcquisitionError.unavailable
        }

        do {
            let descriptor = try openValidatedCacheLock(
                directoryDescriptor: directoryDescriptor
            )
            removeQuarantinedLockLeaf(
                quarantineName,
                metadata: metadata,
                directoryDescriptor: directoryDescriptor
            )
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                Darwin.close(descriptor)
                throw CacheLockAcquisitionError.unavailable
            }
            return descriptor
        } catch {
            var replacementMetadata = stat()
            if Darwin.fstatat(
                directoryDescriptor,
                Self.cacheLockFileName,
                &replacementMetadata,
                AT_SYMLINK_NOFOLLOW
            ) != 0,
               errno == ENOENT {
                _ = Darwin.renameatx_np(
                    directoryDescriptor,
                    quarantineName,
                    directoryDescriptor,
                    Self.cacheLockFileName,
                    UInt32(RENAME_EXCL)
                )
            }
            throw error
        }
    }

    private func removeQuarantinedLockLeaf(
        _ name: String,
        metadata: stat,
        directoryDescriptor: Int32
    ) {
        let flags = (metadata.st_mode & S_IFMT) == S_IFDIR
            ? AT_REMOVEDIR
            : 0
        _ = Darwin.unlinkat(directoryDescriptor, name, flags)
    }

    private func isValidCacheLockMetadata(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG &&
            metadata.st_nlink == 1 &&
            metadata.st_uid == geteuid() &&
            metadata.st_mode & 0o777 == 0o600
    }

    private func sameFileIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private func mapCacheLockError(
        _ error: CacheLockAcquisitionError
    ) -> CompatibilityCatalogRepositoryError {
        switch error {
        case .unavailable, .unsafeLeaf, .timedOut:
            .cacheUnavailable
        }
    }

    private func directoryEntryExists(_ url: URL) -> Bool {
        var metadata = stat()
        if Darwin.lstat(url.path, &metadata) == 0 { return true }
        return errno != ENOENT
    }

    private func synchronizeRegularFile(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CompatibilityCatalogRepositoryError.cacheCommitFailed
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw CompatibilityCatalogRepositoryError.cacheCommitFailed
        }
    }

    private func synchronizeDirectory(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CompatibilityCatalogRepositoryError.cacheCommitFailed
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw CompatibilityCatalogRepositoryError.cacheCommitFailed
        }
    }
}

private final class CompatibilityCatalogRemoteDownloader: NSObject, URLSessionDataDelegate,
    URLSessionTaskDelegate, @unchecked Sendable {
    private typealias DownloadResult = Result<(Data, HTTPURLResponse), Error>

    private let expectedURL: URL
    private let maximumBytes: Int
    private let bufferObserver: (@Sendable (Int) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var payload = Data()
    private var wasCancelled = false

    init(
        expectedURL: URL,
        maximumBytes: Int,
        bufferObserver: (@Sendable (Int) -> Void)?
    ) {
        self.expectedURL = expectedURL
        self.maximumBytes = maximumBytes
        self.bufferObserver = bufferObserver
    }

    func fetch(
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if wasCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let createdSession = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                let createdTask = createdSession.dataTask(with: request)
                session = createdSession
                task = createdTask
                lock.unlock()
                createdTask.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        complete(.failure(CompatibilityCatalogRepositoryError.invalidResolvedURL))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard compatibilityCatalogMatchesOfficialEndpoint(response.url, expected: expectedURL) else {
            completionHandler(.cancel)
            complete(.failure(CompatibilityCatalogRepositoryError.invalidResolvedURL))
            return
        }
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            completionHandler(.cancel)
            complete(.failure(CompatibilityCatalogRepositoryError.invalidHTTPStatus(
                (response as? HTTPURLResponse)?.statusCode ?? -1
            )))
            return
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            complete(.failure(CompatibilityCatalogRepositoryError.responseTooLarge(
                Int(clamping: response.expectedContentLength),
                maximumBytes
            )))
            return
        }
        lock.lock()
        self.response = httpResponse
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let nextByteCount = payload.count.addingReportingOverflow(data.count)
        if nextByteCount.overflow || nextByteCount.partialValue > maximumBytes {
            let observedByteCount = nextByteCount.overflow ? Int.max : nextByteCount.partialValue
            let retainedByteCount = payload.count
            lock.unlock()
            bufferObserver?(retainedByteCount)
            complete(.failure(CompatibilityCatalogRepositoryError.responseTooLarge(
                observedByteCount,
                maximumBytes
            )))
            return
        }
        payload.append(data)
        let retainedByteCount = payload.count
        lock.unlock()
        bufferObserver?(retainedByteCount)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            complete(.failure(error))
            return
        }
        lock.lock()
        let response = self.response
        let payload = self.payload
        lock.unlock()
        guard let response else {
            complete(.failure(URLError(.badServerResponse)))
            return
        }
        complete(.success((payload, response)))
    }

    private func cancel() {
        lock.lock()
        wasCancelled = true
        lock.unlock()
        complete(.failure(CancellationError()))
    }

    private func complete(_ result: DownloadResult) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        lock.unlock()

        task?.cancel()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }
}

private func compatibilityCatalogMatchesOfficialEndpoint(_ resolvedURL: URL?, expected: URL) -> Bool {
    guard let resolvedURL,
          let resolved = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false),
          let expectedComponents = URLComponents(url: expected, resolvingAgainstBaseURL: false) else {
        return false
    }
    return resolved.scheme?.lowercased() == "https" &&
        resolved.host?.lowercased() == expectedComponents.host?.lowercased() &&
        resolved.port == expectedComponents.port &&
        resolved.path == expectedComponents.path &&
        resolved.user == nil &&
        resolved.password == nil &&
        resolved.query == nil &&
        resolved.fragment == nil
}
