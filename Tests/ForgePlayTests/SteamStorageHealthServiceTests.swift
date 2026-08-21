import Foundation
import XCTest
@testable import ForgePlay

final class SteamStorageHealthServiceTests: XCTestCase {
    func testValidationErrorTechnicalSummaryPreservesFailureEvidenceFields() {
        let error = SteamStorageAccessValidationError(
            stage: .temporaryFileWrite,
            path: "/Volumes/External/SteamLibrary",
            reason: "read-only fixture"
        )

        let summary = forgePlayTechnicalErrorSummary(error)
        XCTAssertEqual(
            summary,
            "Steam storage access validation failed; " +
                "stage=temporaryFileWrite; " +
                "path=/Volumes/External/SteamLibrary; " +
                "reason=read-only fixture"
        )
        let redacted = Redactor().redact(summary)
        XCTAssertFalse(redacted.contains("/Volumes/External/SteamLibrary"))
        XCTAssertTrue(redacted.contains("/Volumes/[REDACTED_PATH]"))
    }

    func testDirectoryProbeRoundTripsAndDeletesOnlyItsOwnedTemporaryFile() throws {
        let root = try temporaryDirectory(named: "ProbeSuccess")
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appending(path: "existing-game-file.bin")
        try Data("keep-me".utf8).write(to: existing)
        let probeName = ".forgeplay-storage-probe-fixed.tmp"

        try SteamStorageDirectoryProbe.verify(at: root, probeFileName: probeName)

        XCTAssertEqual(try Data(contentsOf: existing), Data("keep-me".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: probeName).path))
    }

    func testDirectoryProbeNeverOverwritesPreexistingProbeName() throws {
        let root = try temporaryDirectory(named: "ProbeCollision")
        defer { try? FileManager.default.removeItem(at: root) }
        let probeName = ".forgeplay-storage-probe-collision.tmp"
        let collision = root.appending(path: probeName)
        let original = Data("user-owned".utf8)
        try original.write(to: collision)

        XCTAssertThrowsError(
            try SteamStorageDirectoryProbe.verify(at: root, probeFileName: probeName)
        ) { error in
            XCTAssertEqual((error as? SteamStorageAccessProbeError)?.stage, .temporaryFileWrite)
        }
        XCTAssertEqual(try Data(contentsOf: collision), original)
    }

    func testDirectoryProbeRejectsProbeNamesThatEscapeTheSelectedDirectory() throws {
        let root = try temporaryDirectory(named: "ProbeNameEscape")
        defer { try? FileManager.default.removeItem(at: root) }
        let escapedName = ".forgeplay-storage-probe-escape-\(UUID().uuidString).tmp"
        let escapedURL = root.deletingLastPathComponent().appending(path: escapedName)
        defer { try? FileManager.default.removeItem(at: escapedURL) }

        XCTAssertThrowsError(
            try SteamStorageDirectoryProbe.verify(
                at: root,
                probeFileName: "../\(escapedName)"
            )
        ) { error in
            XCTAssertEqual((error as? SteamStorageAccessProbeError)?.stage, .temporaryFileWrite)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedURL.path))
    }

    func testDirectoryProbeRejectsSymlinkDirectory() throws {
        let root = try temporaryDirectory(named: "ProbeSymlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "Target", directoryHint: .isDirectory)
        let link = root.appending(path: "Link", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try SteamStorageDirectoryProbe.verify(at: link)) { error in
            XCTAssertEqual((error as? SteamStorageAccessProbeError)?.stage, .directoryValidation)
        }
    }

    func testSelectionValidationProbesSelectedAndRestoredURLsWithBalancedScopes() async throws {
        let root = try temporaryDirectory(named: "SelectionValidation")
        defer { try? FileManager.default.removeItem(at: root) }
        let events = LockedValues<String>()
        let bookmark = Data("validated-bookmark".utf8)
        let service = SteamStorageHealthService(dependencies: .init(
            bookmarkCreator: { url in
                events.append("bookmark:\(url.path)")
                return bookmark
            },
            bookmarkResolver: { data in
                events.append("resolve:\(String(decoding: data, as: UTF8.self))")
                return SecurityScopedBookmarkResolvedURL(url: root, isStale: false)
            },
            securityScopeStarter: { url in
                events.append("start:\(url.path)")
                return true
            },
            securityScopeStopper: { url in
                events.append("stop:\(url.path)")
            },
            directoryProbe: { url in
                events.append("probe:\(url.path)")
            }
        ))

        let validation = try await service.validateSelection(root, requiresSecurityScope: true)

        XCTAssertEqual(validation.root.path, root.standardizedFileURL.path)
        XCTAssertEqual(validation.bookmark, bookmark)
        XCTAssertEqual(validation.resolvedURL.path, root.standardizedFileURL.path)
        XCTAssertEqual(events.values, [
            "start:\(root.path)",
            "probe:\(root.path)",
            "bookmark:\(root.path)",
            "resolve:validated-bookmark",
            "start:\(root.path)",
            "probe:\(root.path)",
            "stop:\(root.path)",
            "stop:\(root.path)"
        ])
    }

    func testSelectionValidationStopsBothScopesWhenRestoredProbeFails() async throws {
        let root = try temporaryDirectory(named: "SelectionFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let probeCount = LockedCounter()
        let scopeStarts = LockedCounter()
        let scopeStops = LockedCounter()
        let service = SteamStorageHealthService(dependencies: .init(
            bookmarkCreator: { _ in Data("bookmark".utf8) },
            bookmarkResolver: { _ in SecurityScopedBookmarkResolvedURL(url: root, isStale: false) },
            securityScopeStarter: { _ in
                scopeStarts.increment()
                return true
            },
            securityScopeStopper: { _ in scopeStops.increment() },
            directoryProbe: { url in
                if probeCount.increment() == 2 {
                    throw SteamStorageAccessProbeError(
                        stage: .temporaryFileWrite,
                        path: url.path,
                        reason: "read-only fixture"
                    )
                }
            }
        ))

        do {
            _ = try await service.validateSelection(root, requiresSecurityScope: true)
            XCTFail("Expected restored probe failure")
        } catch let error as SteamStorageAccessValidationError {
            XCTAssertEqual(error.stage, .temporaryFileWrite)
            XCTAssertEqual(error.path, root.path)
        }
        XCTAssertEqual(scopeStarts.value, 2)
        XCTAssertEqual(scopeStops.value, 2)
    }

    func testSelectionValidationRejectsRequiredScopeBeforeBookmarkCreation() async throws {
        let root = try temporaryDirectory(named: "SelectionNoScope")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmarkCreations = LockedCounter()
        let service = SteamStorageHealthService(dependencies: .init(
            bookmarkCreator: { _ in
                bookmarkCreations.increment()
                return Data("bookmark".utf8)
            },
            bookmarkResolver: { _ in SecurityScopedBookmarkResolvedURL(url: root, isStale: false) },
            securityScopeStarter: { _ in false },
            securityScopeStopper: { _ in XCTFail("An unstarted scope must not be stopped") },
            directoryProbe: { _ in XCTFail("A required scope failure must precede probing") }
        ))

        do {
            _ = try await service.validateSelection(root, requiresSecurityScope: true)
            XCTFail("Expected security scope failure")
        } catch let error as SteamStorageAccessValidationError {
            XCTAssertEqual(error.stage, .securityScope)
        }
        XCTAssertEqual(bookmarkCreations.value, 0)
    }

    func testSelectionValidationCancellationStopsStartedScope() async throws {
        let root = try temporaryDirectory(named: "SelectionCancellation")
        defer { try? FileManager.default.removeItem(at: root) }
        let probeStarted = DispatchSemaphore(value: 0)
        let allowProbeToFinish = DispatchSemaphore(value: 0)
        let scopeStarts = LockedCounter()
        let scopeStops = LockedCounter()
        let service = SteamStorageHealthService(dependencies: .init(
            bookmarkCreator: { _ in Data("bookmark".utf8) },
            bookmarkResolver: { _ in SecurityScopedBookmarkResolvedURL(url: root, isStale: false) },
            securityScopeStarter: { _ in
                scopeStarts.increment()
                return true
            },
            securityScopeStopper: { _ in scopeStops.increment() },
            directoryProbe: { _ in
                probeStarted.signal()
                _ = allowProbeToFinish.wait(timeout: .now() + 5)
                try Task.checkCancellation()
            }
        ))

        let validationTask = Task {
            try await service.validateSelection(root, requiresSecurityScope: true)
        }
        let didStart = await Task.detached {
            waitForSemaphore(probeStarted, timeout: .now() + 5)
        }.value
        XCTAssertTrue(didStart)
        validationTask.cancel()
        allowProbeToFinish.signal()

        do {
            _ = try await validationTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(scopeStarts.value, 1)
        XCTAssertEqual(scopeStops.value, 1)
    }

    func testDiagnosticsClassifyHealthyStaleMissingAndResolutionFailure() async throws {
        let root = try temporaryDirectory(named: "Diagnostics")
        defer { try? FileManager.default.removeItem(at: root) }
        let stops = LockedCounter()
        let service = SteamStorageHealthService(dependencies: .init(
            bookmarkCreator: { _ in Data() },
            bookmarkResolver: { data in
                let value = String(decoding: data, as: UTF8.self)
                if value == "invalid" {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return SecurityScopedBookmarkResolvedURL(
                    url: root,
                    isStale: value == "stale"
                )
            },
            securityScopeStarter: { _ in true },
            securityScopeStopper: { _ in stops.increment() },
            directoryProbe: { _ in }
        ))
        let snapshots = [
            SteamStorageMountSnapshot(id: "healthy", path: root.path, bookmark: Data("healthy".utf8)),
            SteamStorageMountSnapshot(id: "stale", path: root.path, bookmark: Data("stale".utf8)),
            SteamStorageMountSnapshot(id: "missing", path: root.path, bookmark: nil),
            SteamStorageMountSnapshot(id: "invalid", path: root.path, bookmark: Data("invalid".utf8))
        ]

        let reports = try await service.diagnose(snapshots, requiresSecurityScope: true)
        let byID = Dictionary(uniqueKeysWithValues: reports.map { ($0.id, $0) })

        XCTAssertEqual(byID["healthy"]?.status, .healthy)
        XCTAssertNil(byID["healthy"]?.failedStage)
        XCTAssertEqual(byID["stale"]?.status, .degraded)
        XCTAssertEqual(byID["stale"]?.failedStage, .bookmarkRefresh)
        XCTAssertEqual(byID["missing"]?.status, .reconnectRequired)
        XCTAssertEqual(byID["missing"]?.failedStage, .bookmarkResolution)
        XCTAssertEqual(byID["invalid"]?.status, .reconnectRequired)
        XCTAssertEqual(byID["invalid"]?.failedStage, .bookmarkResolution)
        XCTAssertEqual(stops.value, 2)
    }

    func testDiagnosticProbeFailurePreservesFailedStageAndStopsScope() async throws {
        let root = try temporaryDirectory(named: "DiagnosticProbeFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let stops = LockedCounter()
        let service = SteamStorageHealthService(dependencies: .init(
            bookmarkCreator: { _ in Data() },
            bookmarkResolver: { _ in SecurityScopedBookmarkResolvedURL(url: root, isStale: false) },
            securityScopeStarter: { _ in true },
            securityScopeStopper: { _ in stops.increment() },
            directoryProbe: { url in
                throw SteamStorageAccessProbeError(
                    stage: .temporaryFileDeletion,
                    path: url.path,
                    reason: "cleanup denied"
                )
            }
        ))

        let reports = try await service.diagnose(
            [SteamStorageMountSnapshot(id: "mount", path: root.path, bookmark: Data("bookmark".utf8))],
            requiresSecurityScope: true
        )

        XCTAssertEqual(reports.first?.status, .unavailable)
        XCTAssertEqual(reports.first?.failedStage, .temporaryFileDeletion)
        XCTAssertEqual(reports.first?.technicalDetail, "cleanup denied")
        XCTAssertEqual(stops.value, 1)
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamStorageHealth-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) -> Bool {
    semaphore.wait(timeout: timeout) == .success
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
