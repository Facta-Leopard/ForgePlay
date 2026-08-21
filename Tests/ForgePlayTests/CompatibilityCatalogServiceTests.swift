import Darwin
import XCTest
@testable import ForgePlay

private struct CompatibilityCatalogInjectedCommitFailure: Error {}

private final class CompatibilityCatalogCacheSwapObservation:
    @unchecked Sendable {
    private let lock = NSLock()
    private var storedCommittedData: Data?
    private var storedDisplacedData: Data?

    var committedData: Data? {
        lock.withLock { storedCommittedData }
    }

    var displacedData: Data? {
        lock.withLock { storedDisplacedData }
    }

    func record(
        committedCacheURL: URL,
        displacedCacheURL: URL
    ) throws {
        let committed = try Data(contentsOf: committedCacheURL)
        let displaced = try Data(contentsOf: displacedCacheURL)
        lock.withLock {
            storedCommittedData = committed
            storedDisplacedData = displaced
        }
        throw CompatibilityCatalogInjectedCommitFailure()
    }
}

private final class CompatibilityCatalogLockRepairObservation:
    @unchecked Sendable {
    struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private enum WaitError: Error {
        case timedOut
    }

    private let condition = NSCondition()
    private var firstRecoveryGateEntered = false
    private var recoveryGateAcquisitionCount = 0
    private var observedRecoveryGateContention = false
    private var observedLeafContention = false
    private var storedLeafIdentities: [Identity] = []
    private var activeExclusiveSections = 0
    private var exclusiveSectionEntryCount = 0
    private var storedMaximumConcurrentWriters = 0
    private var observedConcurrentWriters = false
    private var storedSynchronizationFailed = false

    var leafIdentities: [Identity] {
        condition.withLock { storedLeafIdentities }
    }

    var maximumConcurrentWriters: Int {
        condition.withLock { storedMaximumConcurrentWriters }
    }

    var didObserveRecoveryGateContention: Bool {
        condition.withLock { observedRecoveryGateContention }
    }

    var didObserveLeafContention: Bool {
        condition.withLock { observedLeafContention }
    }

    var synchronizationFailed: Bool {
        condition.withLock { storedSynchronizationFailed }
    }

    func record(_ event: CompatibilityCatalogRepository.CacheLockEvent) {
        condition.lock()
        defer { condition.unlock() }

        switch event {
        case .recoveryGateFlockAcquired, .leafFlockAcquired:
            break

        case .recoveryGateAcquired:
            recoveryGateAcquisitionCount += 1
            guard recoveryGateAcquisitionCount == 1 else { return }
            firstRecoveryGateEntered = true
            condition.broadcast()
            let deadline = Date(timeIntervalSinceNow: 2)
            while !observedRecoveryGateContention {
                guard condition.wait(until: deadline) else {
                    storedSynchronizationFailed = true
                    condition.broadcast()
                    return
                }
            }

        case .recoveryGateContended:
            observedRecoveryGateContention = true
            condition.broadcast()

        case .leafOpened(let device, let inode):
            storedLeafIdentities.append(Identity(device: device, inode: inode))
            condition.broadcast()

        case .leafContended:
            observedLeafContention = true
            condition.broadcast()

        case .criticalSectionEntered(let exclusive):
            guard exclusive else { return }
            activeExclusiveSections += 1
            exclusiveSectionEntryCount += 1
            storedMaximumConcurrentWriters = max(
                storedMaximumConcurrentWriters,
                activeExclusiveSections
            )
            if activeExclusiveSections > 1 {
                observedConcurrentWriters = true
            }
            condition.broadcast()
            guard exclusiveSectionEntryCount == 1 else { return }
            let deadline = Date(timeIntervalSinceNow: 2)
            while !observedLeafContention && !observedConcurrentWriters {
                guard condition.wait(until: deadline) else {
                    storedSynchronizationFailed = true
                    condition.broadcast()
                    return
                }
            }

        case .criticalSectionExited(let exclusive):
            guard exclusive else { return }
            activeExclusiveSections -= 1
            condition.broadcast()
        }
    }

    func waitForFirstRecoveryGate(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition.withLock({ firstRecoveryGateEntered }) {
            guard clock.now < deadline else {
                throw WaitError.timedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private final class CompatibilityCatalogLockDeadlineObservation:
    @unchecked Sendable {
    enum Trigger {
        case recoveryGateFlockAcquired
        case leafOpened
    }

    private let lock = NSLock()
    private var delayed = false
    private let delay: TimeInterval
    private let trigger: Trigger

    init(
        delay: TimeInterval,
        trigger: Trigger = .recoveryGateFlockAcquired
    ) {
        self.delay = delay
        self.trigger = trigger
    }

    func record(_ event: CompatibilityCatalogRepository.CacheLockEvent) {
        let matchesTrigger: Bool
        switch (trigger, event) {
        case (.recoveryGateFlockAcquired, .recoveryGateFlockAcquired),
             (.leafOpened, .leafOpened):
            matchesTrigger = true
        default:
            matchesTrigger = false
        }
        guard matchesTrigger else { return }
        let shouldDelay = lock.withLock { () -> Bool in
            guard !delayed else { return false }
            delayed = true
            return true
        }
        if shouldDelay {
            Thread.sleep(forTimeInterval: delay)
        }
    }
}

private final class CompatibilityCatalogLockSubstitutionObservation:
    @unchecked Sendable {
    private let lock = NSLock()
    private let lockURL: URL
    private let displacedURL: URL
    private var didSubstitute = false
    private var storedErrorCode: Int32?
    private var storedLeafIdentities: [
        CompatibilityCatalogLockRepairObservation.Identity
    ] = []

    init(lockURL: URL, displacedURL: URL) {
        self.lockURL = lockURL
        self.displacedURL = displacedURL
    }

    var errorCode: Int32? {
        lock.withLock { storedErrorCode }
    }

    var leafIdentities: [CompatibilityCatalogLockRepairObservation.Identity] {
        lock.withLock { storedLeafIdentities }
    }

    func record(_ event: CompatibilityCatalogRepository.CacheLockEvent) {
        switch event {
        case .leafFlockAcquired:
            let shouldSubstitute = lock.withLock { () -> Bool in
                guard !didSubstitute else { return false }
                didSubstitute = true
                return true
            }
            guard shouldSubstitute else { return }
            guard Darwin.rename(lockURL.path, displacedURL.path) == 0 else {
                lock.withLock { storedErrorCode = errno }
                return
            }
            let descriptor = Darwin.open(
                lockURL.path,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                lock.withLock { storedErrorCode = errno }
                return
            }
            if Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) != 0 {
                lock.withLock { storedErrorCode = errno }
            }
            _ = Darwin.close(descriptor)

        case let .leafOpened(device, inode):
            lock.withLock {
                storedLeafIdentities.append(
                    CompatibilityCatalogLockRepairObservation.Identity(
                        device: device,
                        inode: inode
                    )
                )
            }

        case .recoveryGateFlockAcquired,
             .recoveryGateAcquired,
             .recoveryGateContended,
             .leafContended,
             .criticalSectionEntered,
             .criticalSectionExited:
            break
        }
    }
}

@MainActor
final class CompatibilityCatalogServiceTests: XCTestCase {
    func testServiceAcceptsSchemaV1AndDeclaredV2Fields() throws {
        let service = CompatibilityCatalogService()
        let version1 = try service.loadSnapshot(data: snapshotData(schemaVersion: 1, updatedAt: "2026-08-01"))
        let version2Data = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-03",
            profileForgePlayVersion: "1.0",
            runtimeVersion: "Wine 11.12",
            steamAppID: "553850",
            forgePlayVersion: "1.0",
            gameVersion: "2026.08",
            renderer: "D3DMetal",
            compatibilityOptions: ["rosetta-avx", "game-mode"]
        )
        let version2 = try service.loadSnapshot(data: version2Data)
        let prettyVersion2 = try service.loadSnapshot(
            data: try JSONSerialization.data(
                withJSONObject: JSONSerialization.jsonObject(with: version2Data),
                options: [.prettyPrinted]
            )
        )

        XCTAssertEqual(version1.schemaVersion, 1)
        XCTAssertEqual(version2.schemaVersion, 2)
        XCTAssertEqual(version2.testProfiles.first?.forgePlayVersion, "1.0")
        XCTAssertEqual(version2.testProfiles.first?.runtimeVersion, "Wine 11.12")
        XCTAssertEqual(version2.games.first?.steamAppId, "553850")
        XCTAssertEqual(version2.reports.first?.forgePlayVersion, "1.0")
        XCTAssertEqual(version2.reports.first?.gameVersion, "2026.08")
        XCTAssertEqual(version2.reports.first?.renderer, "D3DMetal")
        XCTAssertEqual(version2.reports.first?.compatibilityOptions, ["rosetta-avx", "game-mode"])
        XCTAssertEqual(version2.sourcePayloadSHA256?.count, 64)
        XCTAssertEqual(version2.sourcePayloadSHA256, prettyVersion2.sourcePayloadSHA256)
    }

    func testServiceRejectsUnsupportedSchemaAndOversizedPayload() throws {
        let service = CompatibilityCatalogService()

        XCTAssertThrowsError(
            try service.loadSnapshot(data: snapshotData(schemaVersion: 3, updatedAt: "2026-08-03"))
        ) { error in
            guard case CompatibilityCatalogServiceError.unsupportedSchemaVersion(3) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let oversized = Data(
            repeating: UInt8(ascii: "x"),
            count: CompatibilityCatalogService.maximumSnapshotBytes + 1
        )
        XCTAssertThrowsError(try service.loadSnapshot(data: oversized)) { error in
            guard case CompatibilityCatalogServiceError.snapshotTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testServiceRejectsUnknownKeysMissingRequiredKeysAndV1VersionFields() throws {
        let service = CompatibilityCatalogService()

        var version1 = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: snapshotData(schemaVersion: 1, updatedAt: "2026-08-01")
            ) as? [String: Any]
        )
        var version1Reports = try XCTUnwrap(version1["reports"] as? [[String: Any]])
        version1Reports[0]["forgePlayVersion"] = "1.0"
        version1["reports"] = version1Reports
        XCTAssertThrowsError(try service.loadSnapshot(data: try jsonData(version1))) { error in
            guard case CompatibilityCatalogServiceError.snapshotDecodeFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        var version1ProfileExtension = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: snapshotData(schemaVersion: 1, updatedAt: "2026-08-01")
            ) as? [String: Any]
        )
        var version1Profiles = try XCTUnwrap(version1ProfileExtension["testProfiles"] as? [[String: Any]])
        version1Profiles[0]["runtimeVersion"] = "Wine 11.12"
        version1ProfileExtension["testProfiles"] = version1Profiles
        XCTAssertThrowsError(try service.loadSnapshot(data: try jsonData(version1ProfileExtension)))

        var version1GameExtension = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: snapshotData(schemaVersion: 1, updatedAt: "2026-08-01")
            ) as? [String: Any]
        )
        var version1Games = try XCTUnwrap(version1GameExtension["games"] as? [[String: Any]])
        version1Games[0]["steamAppId"] = "553850"
        version1GameExtension["games"] = version1Games
        XCTAssertThrowsError(try service.loadSnapshot(data: try jsonData(version1GameExtension)))

        var version2 = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: snapshotData(
                    schemaVersion: 2,
                    updatedAt: "2026-08-03",
                    forgePlayVersion: "1.0"
                )
            ) as? [String: Any]
        )
        var version2Profiles = try XCTUnwrap(version2["testProfiles"] as? [[String: Any]])
        version2Profiles[0]["unexpectedField"] = true
        version2["testProfiles"] = version2Profiles
        XCTAssertThrowsError(try service.loadSnapshot(data: try jsonData(version2)))

        version2Profiles[0].removeValue(forKey: "macOSVersion")
        version2Profiles[0].removeValue(forKey: "unexpectedField")
        version2["testProfiles"] = version2Profiles
        XCTAssertThrowsError(try service.loadSnapshot(data: try jsonData(version2)))

        var version2UnknownGame = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: snapshotData(schemaVersion: 2, updatedAt: "2026-08-03")
            ) as? [String: Any]
        )
        var version2Games = try XCTUnwrap(version2UnknownGame["games"] as? [[String: Any]])
        version2Games[0]["unexpectedField"] = true
        version2UnknownGame["games"] = version2Games
        XCTAssertThrowsError(try service.loadSnapshot(data: try jsonData(version2UnknownGame)))

        var version2UnknownReport = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: snapshotData(schemaVersion: 2, updatedAt: "2026-08-03")
            ) as? [String: Any]
        )
        var version2Reports = try XCTUnwrap(version2UnknownReport["reports"] as? [[String: Any]])
        version2Reports[0]["unexpectedField"] = true
        version2UnknownReport["reports"] = version2Reports
        XCTAssertThrowsError(try service.loadSnapshot(data: try jsonData(version2UnknownReport)))
    }

    func testServiceValidatesEveryPresentV2OptionalField() throws {
        let service = CompatibilityCatalogService()
        var nullable = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: snapshotData(schemaVersion: 2, updatedAt: "2026-08-03")
            ) as? [String: Any]
        )
        var profiles = try XCTUnwrap(nullable["testProfiles"] as? [[String: Any]])
        profiles[0]["forgePlayVersion"] = NSNull()
        profiles[0]["runtimeVersion"] = NSNull()
        nullable["testProfiles"] = profiles
        var games = try XCTUnwrap(nullable["games"] as? [[String: Any]])
        games[0]["steamAppId"] = NSNull()
        nullable["games"] = games
        var reports = try XCTUnwrap(nullable["reports"] as? [[String: Any]])
        reports[0]["forgePlayVersion"] = NSNull()
        reports[0]["gameVersion"] = NSNull()
        reports[0]["renderer"] = NSNull()
        reports[0]["compatibilityOptions"] = NSNull()
        nullable["reports"] = reports
        XCTAssertNoThrow(try service.loadSnapshot(data: try jsonData(nullable)))

        profiles[0]["runtimeVersion"] = "   "
        nullable["testProfiles"] = profiles
        XCTAssertThrowsError(try service.loadSnapshot(data: try jsonData(nullable))) { error in
            guard case CompatibilityCatalogServiceError.invalidTestProfile = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        profiles[0]["runtimeVersion"] = NSNull()
        nullable["testProfiles"] = profiles
        games[0]["steamAppId"] = "１２３"
        nullable["games"] = games
        XCTAssertThrowsError(try service.loadSnapshot(data: try jsonData(nullable))) { error in
            guard case CompatibilityCatalogServiceError.invalidIdentifier = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        games[0]["steamAppId"] = NSNull()
        nullable["games"] = games
        reports[0]["renderer"] = "\n"
        nullable["reports"] = reports
        XCTAssertThrowsError(try service.loadSnapshot(data: try jsonData(nullable))) { error in
            guard case CompatibilityCatalogServiceError.invalidLocalizedText = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        reports[0]["renderer"] = NSNull()
        reports[0]["compatibilityOptions"] = [String]()
        nullable["reports"] = reports
        XCTAssertThrowsError(try service.loadSnapshot(data: try jsonData(nullable))) { error in
            guard case CompatibilityCatalogServiceError.invalidLocalizedText = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDescriptorBoundReadRejectsMultipleLinks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try snapshotData(schemaVersion: 1, updatedAt: "2026-08-01").write(to: fixture.bundled)
        let secondLink = fixture.root.appending(path: "catalog-hard-link.json")
        try FileManager.default.linkItem(at: fixture.bundled, to: secondLink)

        XCTAssertThrowsError(try CompatibilityCatalogService().loadSnapshot(at: secondLink)) { error in
            guard case CompatibilityCatalogServiceError.unsafeSnapshot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDefaultRemoteSessionHasNoSharedCacheCookiesOrCredentials() {
        let configuration = CompatibilityCatalogRepository.defaultRemoteSessionConfiguration()

        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 20)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 60)
    }

    func testLocalLoadUsesNewerCacheWithoutNetwork() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try snapshotData(schemaVersion: 1, updatedAt: "2026-08-01").write(to: fixture.bundled)
        try FileManager.default.createDirectory(at: fixture.cacheDirectory, withIntermediateDirectories: true)
        try snapshotData(schemaVersion: 2, updatedAt: "2026-08-03").write(to: fixture.cache)

        let session = CompatibilityCatalogURLProtocol.session { _ in
            XCTFail("Local catalog loading must not start a network request")
            throw URLError(.badURL)
        }
        let repository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            session: session
        )

        let loaded = try await repository.loadCurrent()

        XCTAssertEqual(loaded.origin, .cached)
        XCTAssertEqual(loaded.snapshot.schemaVersion, 2)
        XCTAssertEqual(loaded.snapshot.updatedAt, "2026-08-03")
        XCTAssertNil(loaded.cacheWarningKey)
    }

    func testOldOrUnsafeCacheFallsBackToBundledSnapshot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try snapshotData(schemaVersion: 2, updatedAt: "2026-08-03").write(to: fixture.bundled)
        try FileManager.default.createDirectory(at: fixture.cacheDirectory, withIntermediateDirectories: true)
        try snapshotData(schemaVersion: 1, updatedAt: "2026-08-01").write(to: fixture.cache)
        let repository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory
        )

        let oldCacheResult = try await repository.loadCurrent()
        XCTAssertEqual(oldCacheResult.origin, .bundled)
        XCTAssertNil(oldCacheResult.cacheWarningKey)

        try FileManager.default.removeItem(at: fixture.cache)
        let external = fixture.root.appending(path: "external.json")
        try snapshotData(schemaVersion: 2, updatedAt: "2026-08-04").write(to: external)
        try FileManager.default.createSymbolicLink(at: fixture.cache, withDestinationURL: external)

        let unsafeCacheResult = try await repository.loadCurrent()
        XCTAssertEqual(unsafeCacheResult.origin, .bundled)
        XCTAssertNotNil(unsafeCacheResult.cacheWarningKey)
        XCTAssertEqual(unsafeCacheResult.snapshot.updatedAt, "2026-08-03")
    }

    func testEqualDateBundledCacheConflictPrefersAndRepairsTrustedBundledSnapshot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundledData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-03",
            forgePlayVersion: "bundled"
        )
        let conflictingCacheData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-03",
            forgePlayVersion: "conflicting-cache"
        )
        try bundledData.write(to: fixture.bundled)
        try FileManager.default.createDirectory(at: fixture.cacheDirectory, withIntermediateDirectories: true)
        try conflictingCacheData.write(to: fixture.cache)
        let repository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory
        )

        let repaired = try await repository.loadCurrent()

        XCTAssertEqual(repaired.origin, .bundled)
        XCTAssertEqual(repaired.snapshot.reports.first?.forgePlayVersion, "bundled")
        XCTAssertEqual(
            repaired.cacheWarningKey,
            "같은 기준일의 저장된 공개 호환성 목록이 앱 포함 목록과 달라 신뢰할 수 있는 앱 포함 목록으로 복구했습니다."
        )
        XCTAssertEqual(try Data(contentsOf: fixture.cache), bundledData)
        try FileSystemItemPolicy.requireRegularNonSymlinkFile(fixture.cache)

        let reloaded = try await repository.loadCurrent()
        XCTAssertEqual(reloaded.origin, .cached)
        XCTAssertNil(reloaded.cacheWarningKey)
        XCTAssertEqual(
            reloaded.snapshot.sourcePayloadSHA256,
            repaired.snapshot.sourcePayloadSHA256
        )
    }

    func testExplicitRefreshValidatesAndAtomicallyCommitsOfficialSnapshot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundledData = try snapshotData(schemaVersion: 1, updatedAt: "2026-08-01")
        let remoteData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-03",
            forgePlayVersion: "1.0"
        )
        try bundledData.write(to: fixture.bundled)
        let endpoint = try XCTUnwrap(CompatibilityCatalogRepository.officialEndpointURL)
        let session = CompatibilityCatalogURLProtocol.session { request in
            XCTAssertEqual(request.url, endpoint)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            return try Self.response(url: endpoint, statusCode: 200, data: remoteData)
        }
        let repository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: session
        )

        let current = try await repository.loadCurrent()
        let refreshed = try await repository.refresh(current: current.snapshot)
        let reloaded = try await repository.loadCurrent()

        XCTAssertEqual(refreshed.origin, .refreshed)
        XCTAssertEqual(refreshed.snapshot.updatedAt, "2026-08-03")
        XCTAssertEqual(reloaded.origin, .cached)
        XCTAssertEqual(reloaded.snapshot.sourcePayloadSHA256, refreshed.snapshot.sourcePayloadSHA256)
        try FileSystemItemPolicy.requireRegularNonSymlinkFile(fixture.cache)
        XCTAssertEqual(
            try fixture.cache.resourceValues(forKeys: [.linkCountKey]).linkCount,
            1
        )
        XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.cacheDirectory.path), true)
    }

    func testExistingCacheAtomicSwapRollsBackAtPostSwapCheckpoint()
        async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundledData = try snapshotData(
            schemaVersion: 1,
            updatedAt: "2026-08-01"
        )
        let previousData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-03",
            forgePlayVersion: "previous"
        )
        let refreshedData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-04",
            forgePlayVersion: "refreshed"
        )
        try bundledData.write(to: fixture.bundled)
        try FileManager.default.createDirectory(
            at: fixture.cacheDirectory,
            withIntermediateDirectories: true
        )
        try previousData.write(to: fixture.cache)
        let endpoint = try XCTUnwrap(
            CompatibilityCatalogRepository.officialEndpointURL
        )
        let observation = CompatibilityCatalogCacheSwapObservation()
        let interruptedRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(
                    url: endpoint,
                    statusCode: 200,
                    data: refreshedData
                )
            },
            cacheCommitCheckpoint: { committedURL, displacedURL in
                try observation.record(
                    committedCacheURL: committedURL,
                    displacedCacheURL: displacedURL
                )
            }
        )
        let current = try await interruptedRepository.loadCurrent()

        do {
            _ = try await interruptedRepository.refresh(
                current: current.snapshot
            )
            XCTFail("Expected injected post-swap failure")
        } catch CompatibilityCatalogRepositoryError.cacheCommitFailed {
            // Expected after the atomic swap-back restores the old cache.
        }

        XCTAssertEqual(observation.committedData, refreshedData)
        XCTAssertEqual(observation.displacedData, previousData)
        XCTAssertEqual(try Data(contentsOf: fixture.cache), previousData)
        try FileSystemItemPolicy.requireRegularNonSymlinkFile(fixture.cache)

        let successfulRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(
                    url: endpoint,
                    statusCode: 200,
                    data: refreshedData
                )
            }
        )
        let successfulCurrent = try await successfulRepository.loadCurrent()
        let refreshed = try await successfulRepository.refresh(
            current: successfulCurrent.snapshot
        )

        XCTAssertEqual(refreshed.origin, .refreshed)
        XCTAssertEqual(try Data(contentsOf: fixture.cache), refreshedData)
        let residue = try FileManager.default.contentsOfDirectory(
            atPath: fixture.cacheDirectory.path
        ).filter {
            $0.hasPrefix(".compatibility-games.")
        }
        XCTAssertTrue(residue.isEmpty)
    }

    func testEqualDateRefreshRequiresCanonicalIdentityAndNeverMutatesCache() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let currentData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-03",
            forgePlayVersion: "1.0"
        )
        let canonicalEquivalentData = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: currentData),
            options: [.prettyPrinted]
        )
        try currentData.write(to: fixture.bundled)
        try FileManager.default.createDirectory(at: fixture.cacheDirectory, withIntermediateDirectories: true)
        try currentData.write(to: fixture.cache)
        let originalCache = try Data(contentsOf: fixture.cache)
        let endpoint = try XCTUnwrap(CompatibilityCatalogRepository.officialEndpointURL)
        let identicalRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(url: endpoint, statusCode: 200, data: canonicalEquivalentData)
            }
        )
        let current = try await identicalRepository.loadCurrent()

        let identical = try await identicalRepository.refresh(current: current.snapshot)

        XCTAssertEqual(identical.snapshot.sourcePayloadSHA256, current.snapshot.sourcePayloadSHA256)
        XCTAssertEqual(try Data(contentsOf: fixture.cache), originalCache)

        let conflictingData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-03",
            forgePlayVersion: "same-date-different-payload"
        )
        let conflictingRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(url: endpoint, statusCode: 200, data: conflictingData)
            }
        )
        do {
            _ = try await conflictingRepository.refresh(current: current.snapshot)
            XCTFail("Expected an equal-date payload conflict")
        } catch CompatibilityCatalogRepositoryError.revisionConflict(let updatedAt) {
            XCTAssertEqual(updatedAt, "2026-08-03")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.cache), originalCache)
    }

    func testRefreshRejectsRedirectAndRollbackWithoutChangingExistingCache() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let currentData = try snapshotData(schemaVersion: 2, updatedAt: "2026-08-03")
        try currentData.write(to: fixture.bundled)
        try FileManager.default.createDirectory(at: fixture.cacheDirectory, withIntermediateDirectories: true)
        try currentData.write(to: fixture.cache)
        let originalCache = try Data(contentsOf: fixture.cache)
        let endpoint = try XCTUnwrap(CompatibilityCatalogRepository.officialEndpointURL)

        let redirectStopped = expectation(description: "redirect task cancelled")
        let redirectedSession = CompatibilityCatalogURLProtocol.scenarioSession { request in
            let redirectResponse = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://example.com/compatibility-games.json"]
                )
            )
            let redirectedRequest = URLRequest(
                url: URL(string: "https://example.com/compatibility-games.json")!
            )
            return .redirect(
                response: redirectResponse,
                request: redirectedRequest,
                onStop: { redirectStopped.fulfill() }
            )
        }
        let redirectedRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: redirectedSession
        )
        let current = try await redirectedRepository.loadCurrent()
        do {
            _ = try await redirectedRepository.refresh(current: current.snapshot)
            XCTFail("Expected redirected response to be rejected")
        } catch CompatibilityCatalogRepositoryError.invalidResolvedURL {
            // Expected.
        }
        await fulfillment(of: [redirectStopped], timeout: 1)
        XCTAssertEqual(try Data(contentsOf: fixture.cache), originalCache)

        let rollbackData = try snapshotData(schemaVersion: 1, updatedAt: "2026-08-01")
        let rollbackSession = CompatibilityCatalogURLProtocol.session { _ in
            try Self.response(url: endpoint, statusCode: 200, data: rollbackData)
        }
        let rollbackRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: rollbackSession
        )
        do {
            _ = try await rollbackRepository.refresh(current: current.snapshot)
            XCTFail("Expected catalog rollback to be rejected")
        } catch CompatibilityCatalogRepositoryError.rollback(let currentDate, let receivedDate) {
            XCTAssertEqual(currentDate, "2026-08-03")
            XCTAssertEqual(receivedDate, "2026-08-01")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.cache), originalCache)
    }

    func testOfflineRefreshPreservesExistingCache() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let currentData = try snapshotData(schemaVersion: 2, updatedAt: "2026-08-03")
        try currentData.write(to: fixture.bundled)
        try FileManager.default.createDirectory(at: fixture.cacheDirectory, withIntermediateDirectories: true)
        try currentData.write(to: fixture.cache)
        let originalCache = try Data(contentsOf: fixture.cache)
        let session = CompatibilityCatalogURLProtocol.session { _ in
            throw URLError(.notConnectedToInternet)
        }
        let repository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            session: session
        )
        let current = try await repository.loadCurrent()

        do {
            _ = try await repository.refresh(current: current.snapshot)
            XCTFail("Expected offline refresh to fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.cache), originalCache)
        XCTAssertEqual(current.snapshot.updatedAt, "2026-08-03")
    }

    func testStreamingRefreshCancelsImmediatelyAboveMaximumBodySize() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let currentData = try snapshotData(schemaVersion: 2, updatedAt: "2026-08-03")
        try currentData.write(to: fixture.bundled)
        try FileManager.default.createDirectory(at: fixture.cacheDirectory, withIntermediateDirectories: true)
        try currentData.write(to: fixture.cache)
        let originalCache = try Data(contentsOf: fixture.cache)
        let endpoint = try XCTUnwrap(CompatibilityCatalogRepository.officialEndpointURL)
        let streamStopped = expectation(description: "oversized stream cancelled")
        let observation = CompatibilityCatalogStreamObservation()
        let boundedChunkSize = 64 * 1024
        let chunks = [
            Data(
                repeating: UInt8(ascii: "a"),
                count: CompatibilityCatalogService.maximumSnapshotBytes - (boundedChunkSize / 2)
            ),
            Data(repeating: UInt8(ascii: "b"), count: boundedChunkSize),
            Data(repeating: UInt8(ascii: "c"), count: boundedChunkSize)
        ]
        let session = CompatibilityCatalogURLProtocol.scenarioSession { _ in
            observation.recordRequest()
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: endpoint,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return .stream(
                response: response,
                chunks: chunks,
                stopCheckpointAfterChunkCount: 2,
                onChunk: { chunk in
                    observation.recordChunk(byteCount: chunk.count)
                },
                onStop: {
                    observation.recordStop()
                    streamStopped.fulfill()
                }
            )
        }
        let repository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: session,
            remoteBufferObserver: { byteCount in
                observation.recordBufferedByteCount(byteCount)
            }
        )
        let current = try await repository.loadCurrent()

        do {
            _ = try await repository.refresh(current: current.snapshot)
            XCTFail("Expected an oversized streamed response to fail")
        } catch CompatibilityCatalogRepositoryError.responseTooLarge(let byteCount, let limit) {
            XCTAssertEqual(
                byteCount,
                CompatibilityCatalogService.maximumSnapshotBytes + (boundedChunkSize / 2)
            )
            XCTAssertEqual(limit, CompatibilityCatalogService.maximumSnapshotBytes)
            XCTAssertLessThanOrEqual(byteCount, limit + boundedChunkSize)
        }
        await fulfillment(of: [streamStopped], timeout: 2)
        XCTAssertTrue(observation.wasStopped)
        XCTAssertEqual(observation.requestCount, 1)
        XCTAssertEqual(observation.chunkCount, 2)
        XCTAssertEqual(
            observation.emittedByteCount,
            CompatibilityCatalogService.maximumSnapshotBytes + (boundedChunkSize / 2)
        )
        XCTAssertLessThanOrEqual(
            observation.emittedByteCount,
            CompatibilityCatalogService.maximumSnapshotBytes + boundedChunkSize
        )
        XCTAssertLessThanOrEqual(
            observation.bufferHighWaterMark,
            CompatibilityCatalogService.maximumSnapshotBytes
        )
        XCTAssertEqual(try Data(contentsOf: fixture.cache), originalCache)
    }

    func testRefreshCancellationStopsNetworkAndPreservesCache() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let currentData = try snapshotData(schemaVersion: 2, updatedAt: "2026-08-03")
        try currentData.write(to: fixture.bundled)
        try FileManager.default.createDirectory(at: fixture.cacheDirectory, withIntermediateDirectories: true)
        try currentData.write(to: fixture.cache)
        let originalCache = try Data(contentsOf: fixture.cache)
        let endpoint = try XCTUnwrap(CompatibilityCatalogRepository.officialEndpointURL)
        let observation = CompatibilityCatalogStreamObservation()
        let session = CompatibilityCatalogURLProtocol.scenarioSession { _ in
            observation.recordRequest()
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: endpoint,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return .stream(
                response: response,
                chunks: [Data("{".utf8), Data("}".utf8)],
                intervalMicroseconds: 1_000_000,
                onStart: {
                    observation.signalRequestStart()
                },
                onChunk: { chunk in
                    observation.recordChunk(byteCount: chunk.count)
                },
                onStop: {
                    observation.recordStop()
                }
            )
        }
        let repository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: session
        )
        let current = try await repository.loadCurrent()
        let refreshTask = Task.detached {
            try await repository.refresh(current: current.snapshot)
        }
        try await observation.waitForRequestStart(timeout: .seconds(5))
        XCTAssertEqual(observation.requestCount, 1)
        refreshTask.cancel()

        do {
            _ = try await refreshTask.value
            XCTFail("Expected refresh cancellation")
        } catch is CancellationError {
            // Expected.
        }
        try await observation.waitForStop(timeout: .seconds(5))
        XCTAssertEqual(observation.requestCount, 1)
        XCTAssertTrue(observation.wasStopped)
        XCTAssertEqual(try Data(contentsOf: fixture.cache), originalCache)
    }

    func testTwoWritersRejectStaleRefreshUnderCacheLock() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try snapshotData(schemaVersion: 1, updatedAt: "2026-08-01").write(to: fixture.bundled)
        let endpoint = try XCTUnwrap(CompatibilityCatalogRepository.officialEndpointURL)
        let staleData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-03",
            forgePlayVersion: "1.0"
        )
        let newestData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-04",
            forgePlayVersion: "1.1"
        )
        let staleRequestStarted = expectation(description: "stale writer downloaded later")
        let newestCommitCompleted = DispatchSemaphore(value: 0)
        let staleFirstChunk = Data(staleData.prefix(staleData.count / 2))
        let staleSecondChunk = Data(staleData.dropFirst(staleData.count / 2))
        let staleSession = CompatibilityCatalogURLProtocol.scenarioSession { _ in
            let (response, _) = try Self.response(
                url: endpoint,
                statusCode: 200,
                data: staleData
            )
            return .stream(
                response: response,
                chunks: [staleFirstChunk, staleSecondChunk],
                onStart: { staleRequestStarted.fulfill() },
                onChunk: { chunk in
                    guard chunk == staleFirstChunk else { return }
                    _ = newestCommitCompleted.wait(timeout: .now() + 5)
                }
            )
        }
        let newestSession = CompatibilityCatalogURLProtocol.session { _ in
            try Self.response(url: endpoint, statusCode: 200, data: newestData)
        }
        let staleRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: staleSession
        )
        let newestRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: newestSession
        )
        let staleCurrent = try await staleRepository.loadCurrent()
        let newestCurrent = try await newestRepository.loadCurrent()
        let staleTask = Task {
            try await staleRepository.refresh(current: staleCurrent.snapshot)
        }
        await fulfillment(of: [staleRequestStarted], timeout: 1)

        let newest = try await newestRepository.refresh(current: newestCurrent.snapshot)
        XCTAssertEqual(newest.snapshot.updatedAt, "2026-08-04")
        newestCommitCompleted.signal()

        do {
            _ = try await staleTask.value
            XCTFail("Expected the late stale writer to be rejected")
        } catch CompatibilityCatalogRepositoryError.rollback(let currentDate, let receivedDate) {
            XCTAssertEqual(currentDate, "2026-08-04")
            XCTAssertEqual(receivedDate, "2026-08-03")
        }
        let final = try await newestRepository.loadCurrent()
        XCTAssertEqual(final.origin, .cached)
        XCTAssertEqual(final.snapshot.updatedAt, "2026-08-04")
        XCTAssertEqual(final.snapshot.sourcePayloadSHA256, newest.snapshot.sourcePayloadSHA256)
    }

    func testTwoWritersRejectEqualDateConflictUnderCacheLock() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try snapshotData(schemaVersion: 1, updatedAt: "2026-08-01").write(to: fixture.bundled)
        let endpoint = try XCTUnwrap(CompatibilityCatalogRepository.officialEndpointURL)
        let lateData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-04",
            forgePlayVersion: "late-conflict"
        )
        let winningData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-04",
            forgePlayVersion: "winner"
        )
        let lateRequestStarted = expectation(description: "late equal-date writer started")
        let winningCommitCompleted = DispatchSemaphore(value: 0)
        let lateFirstChunk = Data(lateData.prefix(lateData.count / 2))
        let lateSecondChunk = Data(lateData.dropFirst(lateData.count / 2))
        let lateSession = CompatibilityCatalogURLProtocol.scenarioSession { _ in
            let (response, _) = try Self.response(
                url: endpoint,
                statusCode: 200,
                data: lateData
            )
            return .stream(
                response: response,
                chunks: [lateFirstChunk, lateSecondChunk],
                onStart: { lateRequestStarted.fulfill() },
                onChunk: { chunk in
                    guard chunk == lateFirstChunk else { return }
                    _ = winningCommitCompleted.wait(timeout: .now() + 5)
                }
            )
        }
        let winningSession = CompatibilityCatalogURLProtocol.session { _ in
            try Self.response(url: endpoint, statusCode: 200, data: winningData)
        }
        let lateRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: lateSession
        )
        let winningRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: winningSession
        )
        let lateCurrent = try await lateRepository.loadCurrent()
        let winningCurrent = try await winningRepository.loadCurrent()
        let lateTask = Task {
            try await lateRepository.refresh(current: lateCurrent.snapshot)
        }
        await fulfillment(of: [lateRequestStarted], timeout: 1)

        let winner = try await winningRepository.refresh(current: winningCurrent.snapshot)
        winningCommitCompleted.signal()

        do {
            _ = try await lateTask.value
            XCTFail("Expected the late equal-date writer to be rejected")
        } catch CompatibilityCatalogRepositoryError.revisionConflict(let updatedAt) {
            XCTAssertEqual(updatedAt, "2026-08-04")
        }
        let final = try await winningRepository.loadCurrent()
        XCTAssertEqual(final.origin, .cached)
        XCTAssertEqual(final.snapshot.reports.first?.forgePlayVersion, "winner")
        XCTAssertEqual(final.snapshot.sourcePayloadSHA256, winner.snapshot.sourcePayloadSHA256)
    }

    func testEqualCallerRefreshReturnsConcurrentNewerCachedRevision() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let currentData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-03",
            forgePlayVersion: "current"
        )
        let newerData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-04",
            forgePlayVersion: "newer"
        )
        try currentData.write(to: fixture.bundled)
        let endpoint = try XCTUnwrap(CompatibilityCatalogRepository.officialEndpointURL)
        let equalRequestStarted = expectation(description: "equal refresh started")
        let newerCommitCompleted = DispatchSemaphore(value: 0)
        let firstChunk = Data(currentData.prefix(currentData.count / 2))
        let secondChunk = Data(currentData.dropFirst(currentData.count / 2))
        let equalSession = CompatibilityCatalogURLProtocol.scenarioSession { _ in
            let (response, _) = try Self.response(
                url: endpoint,
                statusCode: 200,
                data: currentData
            )
            return .stream(
                response: response,
                chunks: [firstChunk, secondChunk],
                onStart: { equalRequestStarted.fulfill() },
                onChunk: { chunk in
                    guard chunk == firstChunk else { return }
                    _ = newerCommitCompleted.wait(timeout: .now() + 5)
                }
            )
        }
        let newerSession = CompatibilityCatalogURLProtocol.session { _ in
            try Self.response(url: endpoint, statusCode: 200, data: newerData)
        }
        let equalRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: equalSession
        )
        let newerRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: newerSession
        )
        let equalCurrent = try await equalRepository.loadCurrent()
        let newerCurrent = try await newerRepository.loadCurrent()
        let equalTask = Task {
            try await equalRepository.refresh(current: equalCurrent.snapshot)
        }
        await fulfillment(of: [equalRequestStarted], timeout: 1)

        let newer = try await newerRepository.refresh(current: newerCurrent.snapshot)
        newerCommitCompleted.signal()
        let reconciled = try await equalTask.value

        XCTAssertEqual(reconciled.origin, .cached)
        XCTAssertEqual(reconciled.snapshot.updatedAt, "2026-08-04")
        XCTAssertEqual(
            reconciled.snapshot.sourcePayloadSHA256,
            newer.snapshot.sourcePayloadSHA256
        )
    }

    func testRefreshRepairsCorruptRegularCacheUnderExclusiveLock() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundledData = try snapshotData(schemaVersion: 1, updatedAt: "2026-08-01")
        let refreshedData = try snapshotData(schemaVersion: 2, updatedAt: "2026-08-04")
        try bundledData.write(to: fixture.bundled)
        try FileManager.default.createDirectory(
            at: fixture.cacheDirectory,
            withIntermediateDirectories: true
        )
        try Data("corrupt-cache".utf8).write(to: fixture.cache)
        let endpoint = try XCTUnwrap(CompatibilityCatalogRepository.officialEndpointURL)
        let repository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(url: endpoint, statusCode: 200, data: refreshedData)
            }
        )
        let current = try await repository.loadCurrent()
        XCTAssertNotNil(current.cacheWarningKey)

        let refreshed = try await repository.refresh(current: current.snapshot)

        XCTAssertEqual(refreshed.origin, .refreshed)
        XCTAssertEqual(try Data(contentsOf: fixture.cache), refreshedData)
        try FileSystemItemPolicy.requireRegularNonSymlinkFile(fixture.cache)
    }

    func testRefreshReplacesFinalCacheSymlinkWithoutFollowingTarget() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundledData = try snapshotData(schemaVersion: 1, updatedAt: "2026-08-01")
        let refreshedData = try snapshotData(schemaVersion: 2, updatedAt: "2026-08-04")
        let externalData = Data("external-target-must-not-change".utf8)
        try bundledData.write(to: fixture.bundled)
        try FileManager.default.createDirectory(
            at: fixture.cacheDirectory,
            withIntermediateDirectories: true
        )
        let external = fixture.root.appending(path: "external-cache-target")
        try externalData.write(to: external)
        try FileManager.default.createSymbolicLink(
            at: fixture.cache,
            withDestinationURL: external
        )
        let endpoint = try XCTUnwrap(CompatibilityCatalogRepository.officialEndpointURL)
        let repository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(url: endpoint, statusCode: 200, data: refreshedData)
            }
        )
        let current = try await repository.loadCurrent()

        _ = try await repository.refresh(current: current.snapshot)

        XCTAssertEqual(try Data(contentsOf: external), externalData)
        XCTAssertEqual(try Data(contentsOf: fixture.cache), refreshedData)
        try FileSystemItemPolicy.requireRegularNonSymlinkFile(fixture.cache)
    }

    func testConcurrentUnsafeLockRepairersConvergeOnOneLeafAndOneWriter()
        async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundledData = try snapshotData(
            schemaVersion: 1,
            updatedAt: "2026-08-01"
        )
        let previousData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-03",
            forgePlayVersion: "previous"
        )
        let firstRefreshData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-04",
            forgePlayVersion: "first"
        )
        let secondRefreshData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-05",
            forgePlayVersion: "second"
        )
        try bundledData.write(to: fixture.bundled)
        try FileManager.default.createDirectory(
            at: fixture.cacheDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(Darwin.chmod(fixture.cacheDirectory.path, 0o700), 0)
        try previousData.write(to: fixture.cache)
        let lockURL = fixture.cacheDirectory.appending(
            path: ".compatibility-catalog.lock"
        )
        try Data().write(to: lockURL)
        XCTAssertEqual(Darwin.chmod(lockURL.path, 0o644), 0)

        let endpoint = try XCTUnwrap(
            CompatibilityCatalogRepository.officialEndpointURL
        )
        let observation = CompatibilityCatalogLockRepairObservation()
        let eventObserver: @Sendable (
            CompatibilityCatalogRepository.CacheLockEvent
        ) -> Void = { event in
            observation.record(event)
        }
        let firstRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(
                    url: endpoint,
                    statusCode: 200,
                    data: firstRefreshData
                )
            },
            cacheLockTimeout: .seconds(3),
            cacheLockRetryDelay: .milliseconds(5),
            cacheLockEventObserver: eventObserver
        )
        let secondRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(
                    url: endpoint,
                    statusCode: 200,
                    data: secondRefreshData
                )
            },
            cacheLockTimeout: .seconds(3),
            cacheLockRetryDelay: .milliseconds(5),
            cacheLockEventObserver: eventObserver
        )
        let current = try CompatibilityCatalogService().loadSnapshot(
            data: bundledData
        )

        let firstTask = Task.detached {
            try await firstRepository.refresh(current: current)
        }
        defer { firstTask.cancel() }
        try await observation.waitForFirstRecoveryGate(timeout: .seconds(1))
        let secondTask = Task.detached {
            try await secondRepository.refresh(current: current)
        }
        defer { secondTask.cancel() }

        let firstResult = try await firstTask.value
        let secondResult = try await secondTask.value

        XCTAssertEqual(firstResult.origin, .refreshed)
        XCTAssertEqual(secondResult.origin, .refreshed)
        XCTAssertTrue(observation.didObserveRecoveryGateContention)
        XCTAssertTrue(observation.didObserveLeafContention)
        XCTAssertFalse(observation.synchronizationFailed)
        XCTAssertEqual(observation.maximumConcurrentWriters, 1)
        let identities = observation.leafIdentities
        XCTAssertEqual(identities.count, 2)
        XCTAssertEqual(identities.first, identities.last)

        var finalLockMetadata = stat()
        XCTAssertEqual(Darwin.lstat(lockURL.path, &finalLockMetadata), 0)
        XCTAssertEqual(finalLockMetadata.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(finalLockMetadata.st_mode & 0o777, 0o600)
        XCTAssertEqual(finalLockMetadata.st_nlink, 1)
        XCTAssertEqual(
            identities.first,
            CompatibilityCatalogLockRepairObservation.Identity(
                device: UInt64(truncatingIfNeeded: finalLockMetadata.st_dev),
                inode: UInt64(truncatingIfNeeded: finalLockMetadata.st_ino)
            )
        )
        XCTAssertEqual(try Data(contentsOf: fixture.cache), secondRefreshData)
        let quarantineResidue = try FileManager.default
            .contentsOfDirectory(atPath: fixture.cacheDirectory.path)
            .filter {
                $0.hasPrefix(".compatibility-catalog.lock.quarantine.")
            }
        XCTAssertTrue(quarantineResidue.isEmpty)
    }

    func testCacheLockSuccessEdgeStillHonorsOriginalDeadline() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundledData = try snapshotData(
            schemaVersion: 1,
            updatedAt: "2026-08-01"
        )
        let cachedData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-03",
            forgePlayVersion: "cached"
        )
        let refreshedData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-04",
            forgePlayVersion: "refreshed"
        )
        try bundledData.write(to: fixture.bundled)
        try FileManager.default.createDirectory(
            at: fixture.cacheDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(Darwin.chmod(fixture.cacheDirectory.path, 0o700), 0)
        try cachedData.write(to: fixture.cache)
        let lockURL = fixture.cacheDirectory.appending(
            path: ".compatibility-catalog.lock"
        )
        try Data().write(to: lockURL)
        XCTAssertEqual(Darwin.chmod(lockURL.path, 0o600), 0)
        var originalLockMetadata = stat()
        XCTAssertEqual(Darwin.lstat(lockURL.path, &originalLockMetadata), 0)

        let endpoint = try XCTUnwrap(
            CompatibilityCatalogRepository.officialEndpointURL
        )
        let observation = CompatibilityCatalogLockDeadlineObservation(
            delay: 0.08
        )
        let repository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(
                    url: endpoint,
                    statusCode: 200,
                    data: refreshedData
                )
            },
            cacheLockTimeout: .milliseconds(20),
            cacheLockRetryDelay: .milliseconds(1),
            cacheLockEventObserver: { event in
                observation.record(event)
            }
        )
        let current = try CompatibilityCatalogService().loadSnapshot(
            data: cachedData
        )

        do {
            _ = try await repository.refresh(current: current)
            XCTFail("Expected the original cache-lock deadline to win")
        } catch CompatibilityCatalogRepositoryError.cacheUnavailable {
            // Acquiring a flock after its original deadline is not success.
        }

        XCTAssertEqual(try Data(contentsOf: fixture.cache), cachedData)
        try assertLockIdentity(lockURL, equals: originalLockMetadata)
    }

    func testCacheLockFinalIdentitySuccessStillHonorsOriginalDeadline()
        async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundledData = try snapshotData(
            schemaVersion: 1,
            updatedAt: "2026-08-01"
        )
        let cachedData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-03",
            forgePlayVersion: "cached"
        )
        let refreshedData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-04",
            forgePlayVersion: "refreshed"
        )
        try bundledData.write(to: fixture.bundled)
        try FileManager.default.createDirectory(
            at: fixture.cacheDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(Darwin.chmod(fixture.cacheDirectory.path, 0o700), 0)
        try cachedData.write(to: fixture.cache)
        let lockURL = fixture.cacheDirectory.appending(
            path: ".compatibility-catalog.lock"
        )
        try Data().write(to: lockURL)
        XCTAssertEqual(Darwin.chmod(lockURL.path, 0o600), 0)
        var originalLockMetadata = stat()
        XCTAssertEqual(Darwin.lstat(lockURL.path, &originalLockMetadata), 0)

        let endpoint = try XCTUnwrap(
            CompatibilityCatalogRepository.officialEndpointURL
        )
        let observation = CompatibilityCatalogLockDeadlineObservation(
            delay: 0.08,
            trigger: .leafOpened
        )
        let repository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(
                    url: endpoint,
                    statusCode: 200,
                    data: refreshedData
                )
            },
            cacheLockTimeout: .milliseconds(20),
            cacheLockRetryDelay: .milliseconds(1),
            cacheLockEventObserver: { event in
                observation.record(event)
            }
        )
        let current = try CompatibilityCatalogService().loadSnapshot(
            data: cachedData
        )

        do {
            _ = try await repository.refresh(current: current)
            XCTFail("Expected final identity validation to honor the deadline")
        } catch CompatibilityCatalogRepositoryError.cacheUnavailable {
            // The validated descriptor must not escape after its deadline.
        }

        XCTAssertEqual(try Data(contentsOf: fixture.cache), cachedData)
        try assertLockIdentity(lockURL, equals: originalLockMetadata)
    }

    func testCacheLockRetriesWhenLeafPathIsSubstitutedAfterFlock()
        async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundledData = try snapshotData(
            schemaVersion: 1,
            updatedAt: "2026-08-01"
        )
        let cachedData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-03",
            forgePlayVersion: "cached"
        )
        let refreshedData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-04",
            forgePlayVersion: "refreshed"
        )
        try bundledData.write(to: fixture.bundled)
        try FileManager.default.createDirectory(
            at: fixture.cacheDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(Darwin.chmod(fixture.cacheDirectory.path, 0o700), 0)
        try cachedData.write(to: fixture.cache)
        let lockURL = fixture.cacheDirectory.appending(
            path: ".compatibility-catalog.lock"
        )
        let displacedURL = fixture.cacheDirectory.appending(
            path: ".compatibility-catalog.lock.injected-displaced"
        )
        try Data().write(to: lockURL)
        XCTAssertEqual(Darwin.chmod(lockURL.path, 0o600), 0)

        let endpoint = try XCTUnwrap(
            CompatibilityCatalogRepository.officialEndpointURL
        )
        let observation = CompatibilityCatalogLockSubstitutionObservation(
            lockURL: lockURL,
            displacedURL: displacedURL
        )
        let repository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(
                    url: endpoint,
                    statusCode: 200,
                    data: refreshedData
                )
            },
            cacheLockTimeout: .seconds(1),
            cacheLockRetryDelay: .milliseconds(1),
            cacheLockEventObserver: { event in
                observation.record(event)
            }
        )
        let current = try CompatibilityCatalogService().loadSnapshot(
            data: cachedData
        )

        let refreshed = try await repository.refresh(current: current)

        XCTAssertEqual(refreshed.origin, .refreshed)
        XCTAssertNil(observation.errorCode)
        XCTAssertGreaterThanOrEqual(observation.leafIdentities.count, 2)
        XCTAssertNotEqual(
            observation.leafIdentities.first,
            observation.leafIdentities.last
        )
        var currentLockMetadata = stat()
        XCTAssertEqual(Darwin.lstat(lockURL.path, &currentLockMetadata), 0)
        XCTAssertEqual(currentLockMetadata.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(currentLockMetadata.st_mode & 0o777, 0o600)
        XCTAssertEqual(currentLockMetadata.st_nlink, 1)
        XCTAssertEqual(
            observation.leafIdentities.last,
            CompatibilityCatalogLockRepairObservation.Identity(
                device: UInt64(
                    truncatingIfNeeded: currentLockMetadata.st_dev
                ),
                inode: UInt64(
                    truncatingIfNeeded: currentLockMetadata.st_ino
                )
            )
        )
        XCTAssertEqual(try Data(contentsOf: fixture.cache), refreshedData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: displacedURL.path))
    }

    func testRecoveryGateDeadlineAndCancellationPreserveLockAndCache()
        async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundledData = try snapshotData(
            schemaVersion: 1,
            updatedAt: "2026-08-01"
        )
        let cachedData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-03"
        )
        let refreshedData = try snapshotData(
            schemaVersion: 2,
            updatedAt: "2026-08-04"
        )
        try bundledData.write(to: fixture.bundled)
        try FileManager.default.createDirectory(
            at: fixture.cacheDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(Darwin.chmod(fixture.cacheDirectory.path, 0o700), 0)
        try cachedData.write(to: fixture.cache)
        let lockURL = fixture.cacheDirectory.appending(
            path: ".compatibility-catalog.lock"
        )
        try Data().write(to: lockURL)
        XCTAssertEqual(Darwin.chmod(lockURL.path, 0o600), 0)
        var originalLockMetadata = stat()
        XCTAssertEqual(Darwin.lstat(lockURL.path, &originalLockMetadata), 0)

        let gateDescriptor = try acquireExclusiveFixtureCacheDirectoryGate(
            fixture
        )
        defer {
            _ = flock(gateDescriptor, LOCK_UN)
            _ = Darwin.close(gateDescriptor)
        }
        let endpoint = try XCTUnwrap(
            CompatibilityCatalogRepository.officialEndpointURL
        )
        let timeoutRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(
                    url: endpoint,
                    statusCode: 200,
                    data: refreshedData
                )
            },
            cacheLockTimeout: .milliseconds(40),
            cacheLockRetryDelay: .seconds(1)
        )

        let fallback = try await timeoutRepository.loadCurrent()

        XCTAssertEqual(fallback.origin, .bundled)
        XCTAssertEqual(fallback.snapshot.updatedAt, "2026-08-01")
        XCTAssertEqual(
            fallback.cacheWarningKey,
            "저장된 공개 호환성 목록 잠금을 안전하게 사용할 수 없어 앱 포함 목록을 사용합니다."
        )
        do {
            _ = try await timeoutRepository.refresh(current: fallback.snapshot)
            XCTFail("Expected recovery-gate timeout")
        } catch CompatibilityCatalogRepositoryError.cacheUnavailable {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: fixture.cache), cachedData)
        try assertLockIdentity(
            lockURL,
            equals: originalLockMetadata
        )

        let loadWaitStarted = CompatibilityCatalogOneShotAsyncSignal()
        let cancellationRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(
                    url: endpoint,
                    statusCode: 200,
                    data: refreshedData
                )
            },
            cacheLockTimeout: .seconds(5),
            cacheLockRetryDelay: .milliseconds(10),
            cacheLockContentionObserver: { loadWaitStarted.signal() }
        )
        let loadTask = Task {
            try await cancellationRepository.loadCurrent()
        }
        try await loadWaitStarted.wait(timeout: .seconds(1))
        loadTask.cancel()
        do {
            _ = try await loadTask.value
            XCTFail("Expected recovery-gate load cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let refreshWaitStarted = CompatibilityCatalogOneShotAsyncSignal()
        let refreshCancellationRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(
                    url: endpoint,
                    statusCode: 200,
                    data: refreshedData
                )
            },
            cacheLockTimeout: .seconds(5),
            cacheLockRetryDelay: .milliseconds(10),
            cacheLockContentionObserver: { refreshWaitStarted.signal() }
        )
        let refreshTask = Task {
            try await refreshCancellationRepository.refresh(
                current: fallback.snapshot
            )
        }
        try await refreshWaitStarted.wait(timeout: .seconds(1))
        refreshTask.cancel()
        do {
            _ = try await refreshTask.value
            XCTFail("Expected recovery-gate refresh cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(try Data(contentsOf: fixture.cache), cachedData)
        try assertLockIdentity(
            lockURL,
            equals: originalLockMetadata
        )
    }

    func testUnsafeLockLeafFallsBackToBundledThenRefreshRepairsOnce()
        async throws {
        for unsafeKind in UnsafeCacheLockKind.allCases {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let bundledData = try snapshotData(
                schemaVersion: 1,
                updatedAt: "2026-08-01"
            )
            let cachedData = try snapshotData(
                schemaVersion: 2,
                updatedAt: "2026-08-03"
            )
            let refreshedData = try snapshotData(
                schemaVersion: 2,
                updatedAt: "2026-08-04"
            )
            try bundledData.write(to: fixture.bundled)
            try FileManager.default.createDirectory(
                at: fixture.cacheDirectory,
                withIntermediateDirectories: true
            )
            try cachedData.write(to: fixture.cache)
            let lockURL = fixture.cacheDirectory.appending(
                path: ".compatibility-catalog.lock"
            )
            let externalLeaf = fixture.root.appending(
                path: "external-lock-\(unsafeKind.rawValue)"
            )
            let externalData = Data("external-lock-must-remain".utf8)
            switch unsafeKind {
            case .symlink:
                try externalData.write(to: externalLeaf)
                try FileManager.default.createSymbolicLink(
                    at: lockURL,
                    withDestinationURL: externalLeaf
                )
            case .mode:
                try Data().write(to: lockURL)
                XCTAssertEqual(Darwin.chmod(lockURL.path, 0o644), 0)
            case .multipleLinks:
                try Data().write(to: lockURL)
                XCTAssertEqual(Darwin.chmod(lockURL.path, 0o600), 0)
                try FileManager.default.linkItem(
                    at: lockURL,
                    to: externalLeaf
                )
            }

            let endpoint = try XCTUnwrap(
                CompatibilityCatalogRepository.officialEndpointURL
            )
            let repository = CompatibilityCatalogRepository(
                bundledSnapshotURL: fixture.bundled,
                cacheRootURL: fixture.root,
                cacheDirectoryURL: fixture.cacheDirectory,
                endpointURL: endpoint,
                session: CompatibilityCatalogURLProtocol.session { _ in
                    try Self.response(
                        url: endpoint,
                        statusCode: 200,
                        data: refreshedData
                    )
                }
            )

            let recoveredLoad = try await repository.loadCurrent()

            XCTAssertEqual(recoveredLoad.origin, .bundled)
            XCTAssertEqual(recoveredLoad.snapshot.updatedAt, "2026-08-01")
            XCTAssertEqual(
                recoveredLoad.cacheWarningKey,
                "저장된 공개 호환성 목록 잠금을 안전하게 사용할 수 없어 앱 포함 목록을 사용합니다."
            )
            if unsafeKind == .symlink {
                XCTAssertEqual(try Data(contentsOf: externalLeaf), externalData)
            }

            let refreshed = try await repository.refresh(
                current: recoveredLoad.snapshot
            )

            XCTAssertEqual(refreshed.origin, .refreshed)
            XCTAssertEqual(try Data(contentsOf: fixture.cache), refreshedData)
            try FileSystemItemPolicy.requireRegularNonSymlinkFile(lockURL)
            var lockMetadata = stat()
            XCTAssertEqual(Darwin.lstat(lockURL.path, &lockMetadata), 0)
            XCTAssertEqual(lockMetadata.st_mode & S_IFMT, S_IFREG)
            XCTAssertEqual(lockMetadata.st_mode & 0o777, 0o600)
            XCTAssertEqual(lockMetadata.st_nlink, 1)
            if unsafeKind == .symlink {
                XCTAssertEqual(try Data(contentsOf: externalLeaf), externalData)
            } else if unsafeKind == .multipleLinks {
                XCTAssertEqual(try Data(contentsOf: externalLeaf), Data())
            }
            let quarantineResidue = try FileManager.default
                .contentsOfDirectory(atPath: fixture.cacheDirectory.path)
                .filter {
                    $0.hasPrefix(
                        ".compatibility-catalog.lock.quarantine."
                    )
                }
            XCTAssertTrue(quarantineResidue.isEmpty)
        }
    }

    func testCacheLockDeadlineAndCancellationLeaveCacheUnchanged() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundledData = try snapshotData(schemaVersion: 1, updatedAt: "2026-08-01")
        let cachedData = try snapshotData(schemaVersion: 2, updatedAt: "2026-08-03")
        let refreshedData = try snapshotData(schemaVersion: 2, updatedAt: "2026-08-04")
        try bundledData.write(to: fixture.bundled)
        try FileManager.default.createDirectory(
            at: fixture.cacheDirectory,
            withIntermediateDirectories: true
        )
        try cachedData.write(to: fixture.cache)
        let lockDescriptor = try acquireExclusiveFixtureCacheLock(fixture)
        var heldLockMetadata = stat()
        XCTAssertEqual(Darwin.fstat(lockDescriptor, &heldLockMetadata), 0)
        defer {
            _ = flock(lockDescriptor, LOCK_UN)
            _ = Darwin.close(lockDescriptor)
        }
        let endpoint = try XCTUnwrap(CompatibilityCatalogRepository.officialEndpointURL)
        let timeoutRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(url: endpoint, statusCode: 200, data: refreshedData)
            },
            cacheLockTimeout: .milliseconds(40),
            cacheLockRetryDelay: .seconds(1)
        )

        let boundedFallback = try await timeoutRepository.loadCurrent()

        XCTAssertEqual(boundedFallback.origin, .bundled)
        XCTAssertEqual(boundedFallback.snapshot.updatedAt, "2026-08-01")
        XCTAssertEqual(
            boundedFallback.cacheWarningKey,
            "저장된 공개 호환성 목록 잠금을 안전하게 사용할 수 없어 앱 포함 목록을 사용합니다."
        )
        var lockPathMetadata = stat()
        XCTAssertEqual(
            Darwin.lstat(
                fixture.cacheDirectory.appending(
                    path: ".compatibility-catalog.lock"
                ).path,
                &lockPathMetadata
            ),
            0
        )
        XCTAssertEqual(lockPathMetadata.st_dev, heldLockMetadata.st_dev)
        XCTAssertEqual(lockPathMetadata.st_ino, heldLockMetadata.st_ino)
        XCTAssertEqual(try Data(contentsOf: fixture.cache), cachedData)

        let callerCurrent = try CompatibilityCatalogService().loadSnapshot(
            data: bundledData
        )
        do {
            _ = try await timeoutRepository.refresh(current: callerCurrent)
            XCTFail("Expected refresh lock acquisition to time out")
        } catch CompatibilityCatalogRepositoryError.cacheUnavailable {
            // Expected.
        }
        XCTAssertEqual(
            Darwin.lstat(
                fixture.cacheDirectory.appending(
                    path: ".compatibility-catalog.lock"
                ).path,
                &lockPathMetadata
            ),
            0
        )
        XCTAssertEqual(lockPathMetadata.st_dev, heldLockMetadata.st_dev)
        XCTAssertEqual(lockPathMetadata.st_ino, heldLockMetadata.st_ino)
        XCTAssertEqual(try Data(contentsOf: fixture.cache), cachedData)

        let loadWaitStarted = CompatibilityCatalogOneShotAsyncSignal()
        let cancellationRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(url: endpoint, statusCode: 200, data: refreshedData)
            },
            cacheLockTimeout: .seconds(5),
            cacheLockRetryDelay: .milliseconds(10),
            cacheLockContentionObserver: { loadWaitStarted.signal() }
        )
        let loadTask = Task {
            try await cancellationRepository.loadCurrent()
        }
        try await loadWaitStarted.wait(timeout: .seconds(1))
        loadTask.cancel()
        do {
            _ = try await loadTask.value
            XCTFail("Expected lock acquisition cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: fixture.cache), cachedData)

        let refreshWaitStarted = CompatibilityCatalogOneShotAsyncSignal()
        let refreshCancellationRepository = CompatibilityCatalogRepository(
            bundledSnapshotURL: fixture.bundled,
            cacheRootURL: fixture.root,
            cacheDirectoryURL: fixture.cacheDirectory,
            endpointURL: endpoint,
            session: CompatibilityCatalogURLProtocol.session { _ in
                try Self.response(url: endpoint, statusCode: 200, data: refreshedData)
            },
            cacheLockTimeout: .seconds(5),
            cacheLockRetryDelay: .milliseconds(10),
            cacheLockContentionObserver: { refreshWaitStarted.signal() }
        )
        let refreshTask = Task {
            try await refreshCancellationRepository.refresh(current: callerCurrent)
        }
        try await refreshWaitStarted.wait(timeout: .seconds(1))
        refreshTask.cancel()
        do {
            _ = try await refreshTask.value
            XCTFail("Expected refresh lock acquisition cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: fixture.cache), cachedData)
    }

    private enum UnsafeCacheLockKind: String, CaseIterable {
        case symlink
        case mode
        case multipleLinks
    }

    private struct Fixture {
        let root: URL
        let bundled: URL
        let cacheDirectory: URL
        let cache: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayCompatibilityCatalogTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cacheDirectory = root
            .appending(path: "ForgePlay", directoryHint: .isDirectory)
            .appending(path: "CompatibilityCatalog", directoryHint: .isDirectory)
        return Fixture(
            root: root,
            bundled: root.appending(path: "bundled.json"),
            cacheDirectory: cacheDirectory,
            cache: cacheDirectory.appending(path: CompatibilityCatalogRepository.cacheFileName)
        )
    }

    private func acquireExclusiveFixtureCacheLock(_ fixture: Fixture) throws -> Int32 {
        _ = Darwin.chmod(fixture.cacheDirectory.path, S_IRWXU)
        let lockURL = fixture.cacheDirectory.appending(
            path: ".compatibility-catalog.lock"
        )
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            throw POSIXError(.EBUSY)
        }
        return descriptor
    }

    private func acquireExclusiveFixtureCacheDirectoryGate(
        _ fixture: Fixture
    ) throws -> Int32 {
        let descriptor = Darwin.open(
            fixture.cacheDirectory.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            throw POSIXError(.EBUSY)
        }
        return descriptor
    }

    private func assertLockIdentity(
        _ lockURL: URL,
        equals expected: stat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var actual = stat()
        XCTAssertEqual(
            Darwin.lstat(lockURL.path, &actual),
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.st_dev,
            expected.st_dev,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.st_ino,
            expected.st_ino,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.st_mode & S_IFMT,
            S_IFREG,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.st_mode & 0o777,
            0o600,
            file: file,
            line: line
        )
        XCTAssertEqual(actual.st_nlink, 1, file: file, line: line)
    }

    private func snapshotData(
        schemaVersion: Int,
        updatedAt: String,
        profileForgePlayVersion: String? = nil,
        runtimeVersion: String? = nil,
        steamAppID: String? = nil,
        forgePlayVersion: String? = nil,
        gameVersion: String? = nil,
        renderer: String? = nil,
        compatibilityOptions: [String]? = nil
    ) throws -> Data {
        var profile: [String: Any] = [
            "id": "apple-silicon-m4",
            "platform": "Apple Silicon Mac",
            "chip": "M4",
            "unifiedMemoryGB": 16,
            "macOSVersion": "26.0"
        ]
        if let profileForgePlayVersion {
            profile["forgePlayVersion"] = profileForgePlayVersion
        }
        if let runtimeVersion { profile["runtimeVersion"] = runtimeVersion }
        var game: [String: Any] = [
            "id": "sample-game",
            "titles": ["en": "Sample Game", "ko": "샘플 게임"]
        ]
        if let steamAppID { game["steamAppId"] = steamAppID }
        var report: [String: Any] = [
            "id": "sample-game-report",
            "gameId": "sample-game",
            "testProfileId": "apple-silicon-m4",
            "status": "playable",
            "source": "project-test",
            "testedAt": updatedAt,
            "notes": ["en": "Playable", "ko": "실행 가능"],
            "blocker": NSNull()
        ]
        if let forgePlayVersion { report["forgePlayVersion"] = forgePlayVersion }
        if let gameVersion { report["gameVersion"] = gameVersion }
        if let renderer { report["renderer"] = renderer }
        if let compatibilityOptions { report["compatibilityOptions"] = compatibilityOptions }
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": schemaVersion,
            "updatedAt": updatedAt,
            "testProfiles": [profile],
            "games": [game],
            "reports": [report]
        ], options: [.sortedKeys])
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private nonisolated static func response(
        url: URL,
        statusCode: Int,
        data: Data
    ) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "Content-Length": String(data.count)
                ]
            )
        )
        return (response, data)
    }
}

private final class CompatibilityCatalogStreamObservation: @unchecked Sendable {
    private let lock = NSLock()
    private let requestStartedSignal = CompatibilityCatalogOneShotAsyncSignal()
    private let stoppedSignal = CompatibilityCatalogOneShotAsyncSignal()
    private var storedRequestCount = 0
    private var storedChunkCount = 0
    private var storedEmittedByteCount = 0
    private var storedBufferHighWaterMark = 0
    private var storedWasStopped = false

    var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    var chunkCount: Int {
        lock.withLock { storedChunkCount }
    }

    var wasStopped: Bool {
        lock.withLock { storedWasStopped }
    }

    var bufferHighWaterMark: Int {
        lock.withLock { storedBufferHighWaterMark }
    }

    var emittedByteCount: Int {
        lock.withLock { storedEmittedByteCount }
    }

    func recordRequest() {
        lock.withLock { storedRequestCount += 1 }
    }

    func signalRequestStart() {
        requestStartedSignal.signal()
    }

    func waitForRequestStart(timeout: Duration) async throws {
        try await requestStartedSignal.wait(timeout: timeout)
    }

    @discardableResult
    func recordChunk(byteCount: Int) -> Int {
        lock.withLock {
            storedChunkCount += 1
            storedEmittedByteCount += byteCount
            return storedChunkCount
        }
    }

    func recordStop() {
        lock.withLock { storedWasStopped = true }
        stoppedSignal.signal()
    }

    func waitForStop(timeout: Duration) async throws {
        try await stoppedSignal.wait(timeout: timeout)
    }

    func recordBufferedByteCount(_ byteCount: Int) {
        lock.withLock {
            storedBufferHighWaterMark = max(storedBufferHighWaterMark, byteCount)
        }
    }
}

private final class CompatibilityCatalogOneShotAsyncSignal: @unchecked Sendable {
    private enum WaitError: Error {
        case timedOut
    }

    private let lock = NSLock()
    private var didSignal = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func signal() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            guard !didSignal else { return [] }
            didSignal = true
            let continuations = Array(waiters.values)
            waiters.removeAll(keepingCapacity: false)
            return continuations
        }
        continuations.forEach { $0.resume(returning: ()) }
    }

    func wait(timeout: Duration) async throws {
        let didObserveSignal = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await self.waitUntilSignaled()
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return false
                } catch {
                    return false
                }
            }
            let firstResult = await group.next() ?? false
            group.cancelAll()
            return firstResult
        }
        guard didObserveSignal else {
            throw WaitError.timedOut
        }
    }

    private func waitUntilSignaled() async throws {
        let waiterID = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediateResult = lock.withLock { () -> Result<Void, Error>? in
                    if didSignal {
                        return .success(())
                    }
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    waiters[waiterID] = continuation
                    return nil
                }
                if let immediateResult {
                    continuation.resume(with: immediateResult)
                }
            }
        } onCancel: {
            self.cancelWaiter(waiterID)
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        let continuation = lock.withLock {
            waiters.removeValue(forKey: waiterID)
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private final class CompatibilityCatalogURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    typealias ScenarioHandler = @Sendable (URLRequest) throws -> Scenario

    enum Scenario {
        case stream(
            response: HTTPURLResponse,
            chunks: [Data],
            intervalMicroseconds: UInt32 = 0,
            stopCheckpointAfterChunkCount: Int? = nil,
            onStart: (@Sendable () -> Void)? = nil,
            onChunk: (@Sendable (Data) -> Void)? = nil,
            onStop: (@Sendable () -> Void)? = nil
        )
        case redirect(
            response: HTTPURLResponse,
            request: URLRequest,
            onStop: (@Sendable () -> Void)? = nil
        )
        case failure(Error)
    }

    private static let scenarioHeader = "X-ForgePlay-Catalog-Test-Scenario"
    private static let registryLock = NSLock()
    private nonisolated(unsafe) static var handlers: [String: ScenarioHandler] = [:]

    private let state = NSCondition()
    private let deliveryQueue = DispatchQueue(
        label: "ForgePlayTests.CompatibilityCatalogURLProtocol.\(UUID().uuidString)"
    )
    private var stopped = false
    private var stopCallback: (@Sendable () -> Void)?
    private var didNotifyStop = false

    static func session(handler: @escaping Handler) -> URLSession {
        scenarioSession { request in
            let (response, data) = try handler(request)
            return .stream(response: response, chunks: [data])
        }
    }

    static func scenarioSession(handler: @escaping ScenarioHandler) -> URLSession {
        let token = UUID().uuidString
        registryLock.withLock { handlers[token] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompatibilityCatalogURLProtocol.self]
        configuration.httpAdditionalHeaders = [scenarioHeader: token]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: scenarioHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let token = request.value(forHTTPHeaderField: Self.scenarioHeader),
              let handler = Self.registryLock.withLock({ Self.handlers[token] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            switch try handler(request) {
            case .stream(
                let response,
                let chunks,
                let intervalMicroseconds,
                let stopCheckpointAfterChunkCount,
                let onStart,
                let onChunk,
                let onStop
            ):
                setStopCallback(onStop)
                onStart?()
                deliveryQueue.async {
                    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    for (index, chunk) in chunks.enumerated() {
                        guard !self.isStopped else { return }
                        self.client?.urlProtocol(self, didLoad: chunk)
                        onChunk?(chunk)
                        if stopCheckpointAfterChunkCount == index + 1,
                           !self.waitForStopCheckpoint(timeout: 5) {
                            return
                        }
                        guard self.waitForNextChunk(
                            intervalMicroseconds: intervalMicroseconds
                        ) else {
                            return
                        }
                    }
                    guard !self.isStopped else { return }
                    self.client?.urlProtocolDidFinishLoading(self)
                }

            case .redirect(let response, let redirectedRequest, let onStop):
                setStopCallback(onStop)
                deliveryQueue.async {
                    guard !self.isStopped else { return }
                    self.client?.urlProtocol(
                        self,
                        wasRedirectedTo: redirectedRequest,
                        redirectResponse: response
                    )
                }

            case .failure(let error):
                deliveryQueue.async {
                    guard !self.isStopped else { return }
                    self.client?.urlProtocol(self, didFailWithError: error)
                }
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        state.lock()
        stopped = true
        let callback: (@Sendable () -> Void)?
        if !didNotifyStop, let stopCallback {
            didNotifyStop = true
            callback = stopCallback
        } else {
            callback = nil
        }
        state.broadcast()
        state.unlock()
        callback?()
    }

    private var isStopped: Bool {
        state.withLock { stopped }
    }

    private func setStopCallback(_ callback: (@Sendable () -> Void)?) {
        state.lock()
        stopCallback = callback
        let callbackToInvoke: (@Sendable () -> Void)?
        if stopped, !didNotifyStop, let callback {
            didNotifyStop = true
            callbackToInvoke = callback
        } else {
            callbackToInvoke = nil
        }
        state.unlock()
        callbackToInvoke?()
    }

    private func waitForNextChunk(intervalMicroseconds: UInt32) -> Bool {
        guard intervalMicroseconds > 0 else { return !isStopped }
        state.lock()
        if !stopped {
            _ = state.wait(until: Date(timeIntervalSinceNow: Double(intervalMicroseconds) / 1_000_000))
        }
        let shouldContinue = !stopped
        state.unlock()
        return shouldContinue
    }

    private func waitForStopCheckpoint(timeout: TimeInterval) -> Bool {
        state.lock()
        if !stopped {
            _ = state.wait(until: Date(timeIntervalSinceNow: timeout))
        }
        let shouldContinue = !stopped
        state.unlock()
        return shouldContinue
    }
}
