import Foundation
import XCTest
@testable import ForgePlay

private actor CompatibilityWaiterProbe {
    struct Call: Equatable, Sendable {
        let prefix: URL
        let timeout: TimeInterval
        let pollInterval: TimeInterval
    }

    private var calls: [Call] = []

    func record(
        prefix: URL,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) {
        calls.append(Call(
            prefix: prefix,
            timeout: timeout,
            pollInterval: pollInterval
        ))
    }

    func recordedCalls() -> [Call] {
        calls
    }
}

@MainActor
final class SteamRouteIsolationTests: XCTestCase {
    func testInactiveCompletionReturnsReconciledTokenWithoutPersistentCapture() async throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: testRoot) }

        let prefix = testRoot.appending(path: "Prefix", directoryHint: .isDirectory)
        let paths = try makeValidPersistentPrefix(
            at: prefix,
            metadata: Data("metadata".utf8),
            libraryFolders: Data("library-folders".utf8),
            fileManager: fileManager
        )
        let redirectedSteamApps = testRoot.appending(
            path: "RedirectedSteamApps",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: redirectedSteamApps,
            withIntermediateDirectories: true
        )
        try Data("redirected-library-folders".utf8).write(
            to: redirectedSteamApps.appending(path: "libraryfolders.vdf")
        )
        let steamApps = paths.libraryFolders.deletingLastPathComponent()
        try fileManager.removeItem(at: steamApps)
        try fileManager.createSymbolicLink(
            at: steamApps,
            withDestinationURL: redirectedSteamApps
        )

        let waiterProbe = CompatibilityWaiterProbe()
        let manager = makeManager(
            fileManager: fileManager,
            compatibilityPrefixExitWaiter: { prefix, timeout, pollInterval in
                await waiterProbe.record(
                    prefix: prefix,
                    timeout: timeout,
                    pollInterval: pollInterval
                )
                return true
            }
        )

        XCTAssertThrowsError(
            try manager.captureCompatibilityPersistentPrefixSnapshot(
                prefix: prefix
            )
        )

        let result = try await manager.completeCompatibilitySessionIfInactive(
            prefix: prefix,
            runtimeExecutable: testRoot.appending(path: "unused-runtime"),
            selection: .d3dMetal,
            videoMemorySizeMB: 12_345,
            persistentStateDigest: "legacy-persistent-digest-must-not-be-read"
        )

        XCTAssertEqual(
            result,
            "forgeplay-transient-compatibility-session-reconciled-v1"
        )
        let waiterCalls = await waiterProbe.recordedCalls()
        XCTAssertEqual(
            waiterCalls,
            [
                CompatibilityWaiterProbe.Call(
                    prefix: prefix,
                    timeout: 0,
                    pollInterval: 0.05
                )
            ]
        )
    }

    func testDirectParentCaptureAndRestoreRoundTrip() throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: testRoot) }

        let prefix = testRoot.appending(path: "Prefix", directoryHint: .isDirectory)
        let paths = try makeValidPersistentPrefix(
            at: prefix,
            metadata: Data("original-metadata".utf8),
            libraryFolders: Data("original-library-folders".utf8),
            fileManager: fileManager
        )
        let manager = makeManager(fileManager: fileManager)
        let snapshot = try manager.captureCompatibilityPersistentPrefixSnapshot(
            prefix: prefix
        )

        try Data("mutated-metadata".utf8).write(to: paths.metadata)
        try Data("mutated-library-folders".utf8).write(
            to: paths.libraryFolders
        )
        try fileManager.removeItem(
            at: paths.dosDevices.appending(path: "c:")
        )
        try fileManager.createSymbolicLink(
            atPath: paths.dosDevices.appending(path: "d:").path,
            withDestinationPath: "/tmp"
        )

        try manager.restoreCompatibilityPersistentPrefixSnapshot(
            snapshot,
            prefix: prefix
        )

        XCTAssertEqual(
            try manager.captureCompatibilityPersistentPrefixSnapshot(
                prefix: prefix
            ),
            snapshot
        )
    }

    func testSymlinkedIntermediateParentRejectsRestoreBeforeMutation() throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: testRoot) }

        let sourcePrefix = testRoot.appending(
            path: "SourcePrefix",
            directoryHint: .isDirectory
        )
        _ = try makeValidPersistentPrefix(
            at: sourcePrefix,
            metadata: Data("restored-metadata".utf8),
            libraryFolders: Data("restored-library-folders".utf8),
            fileManager: fileManager
        )
        let manager = makeManager(fileManager: fileManager)
        let snapshot = try manager.captureCompatibilityPersistentPrefixSnapshot(
            prefix: sourcePrefix
        )

        let targetPrefix = testRoot.appending(
            path: "TargetPrefix",
            directoryHint: .isDirectory
        )
        let redirectedSteamApps = testRoot.appending(
            path: "RedirectedSteamApps",
            directoryHint: .isDirectory
        )
        let redirectedLibraryFolders = redirectedSteamApps.appending(
            path: "libraryfolders.vdf"
        )
        let targetMetadata = targetPrefix.appending(path: "prefix.json")
        let targetSteamDirectory = targetPrefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        let targetDosDevices = targetPrefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        let originalMetadata = Data("target-metadata-must-remain".utf8)
        let originalRedirectedLibrary = Data(
            "redirected-library-must-remain".utf8
        )
        try fileManager.createDirectory(
            at: targetSteamDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: redirectedSteamApps,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: targetDosDevices,
            withIntermediateDirectories: false
        )
        try originalMetadata.write(to: targetMetadata)
        try originalRedirectedLibrary.write(to: redirectedLibraryFolders)
        try fileManager.createSymbolicLink(
            at: targetSteamDirectory.appending(
                path: "steamapps",
                directoryHint: .isDirectory
            ),
            withDestinationURL: redirectedSteamApps
        )

        XCTAssertThrowsError(
            try manager.restoreCompatibilityPersistentPrefixSnapshot(
                snapshot,
                prefix: targetPrefix
            )
        )
        XCTAssertEqual(try Data(contentsOf: targetMetadata), originalMetadata)
        XCTAssertEqual(
            try Data(contentsOf: redirectedLibraryFolders),
            originalRedirectedLibrary
        )
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(atPath: targetDosDevices.path),
            []
        )
    }

    private func makeManager(
        fileManager: FileManager,
        compatibilityPrefixExitWaiter: SteamManager.CompatibilityPrefixExitWaiter? = nil
    ) -> SteamManager {
        SteamManager(
            pathManager: PathManager(),
            runner: SafeProcessRunner(),
            fileManager: fileManager,
            compatibilityPrefixExitWaiter: compatibilityPrefixExitWaiter
        )
    }

    private func makeTemporaryDirectory(
        fileManager: FileManager
    ) throws -> URL {
        let directory = fileManager.temporaryDirectory.appending(
            path: "SteamRouteIsolationTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private func makeValidPersistentPrefix(
        at prefix: URL,
        metadata: Data,
        libraryFolders: Data,
        fileManager: FileManager
    ) throws -> (
        metadata: URL,
        libraryFolders: URL,
        dosDevices: URL
    ) {
        let metadataURL = prefix.appending(path: "prefix.json")
        let libraryFoldersURL = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps/libraryfolders.vdf"
        )
        let dosDevices = prefix.appending(
            path: "dosdevices",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: libraryFoldersURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: dosDevices,
            withIntermediateDirectories: false
        )
        try metadata.write(to: metadataURL)
        try libraryFolders.write(to: libraryFoldersURL)
        try fileManager.createSymbolicLink(
            atPath: dosDevices.appending(path: "c:").path,
            withDestinationPath: "../drive_c"
        )
        try fileManager.createSymbolicLink(
            atPath: dosDevices.appending(path: "z:").path,
            withDestinationPath: "/"
        )
        return (metadataURL, libraryFoldersURL, dosDevices)
    }
}
