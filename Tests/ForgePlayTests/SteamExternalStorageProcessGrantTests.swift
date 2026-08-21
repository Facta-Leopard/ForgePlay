import CryptoKit
import Darwin
import XCTest
@testable import ForgePlay

final class SteamExternalStorageProcessGrantTests: XCTestCase {
    func testPublisherPersistsPrivateImplicitBookmarkManifestAndEnvironment()
        throws
    {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runIdentifier = "6E3B8214-54BD-4635-9BC9-27FC1DB65D04"
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000.125)
        var bookmarkedPaths: [String] = []
        let publisher = SteamExternalStorageProcessGrantPublisher(
            fileManager: .default,
            applicationGroupContainerURLProvider: {
                fixture.applicationGroupContainer
            },
            bridgeURLProvider: { fixture.bridge },
            bookmarkDataProvider: { url in
                bookmarkedPaths.append(url.path)
                return Data("implicit-bookmark:\(url.path)".utf8)
            },
            dateProvider: { createdAt }
        )

        let grant = try publisher.publish(
            roots: [fixture.externalStorage, fixture.externalStorage],
            prefix: fixture.prefix,
            runIdentifier: runIdentifier
        )

        XCTAssertEqual(
            bookmarkedPaths,
            [fixture.externalStorage.resolvingSymlinksInPath().path]
        )
        XCTAssertEqual(
            grant.runIdentifier,
            runIdentifier.lowercased()
        )
        XCTAssertEqual(grant.bridgeURL, fixture.bridge.standardizedFileURL)
        XCTAssertEqual(
            grant.environmentOverrides[
                SteamExternalStorageProcessGrant
                    .manifestFileEnvironmentKey
            ],
            grant.manifestURL.path
        )
        XCTAssertEqual(
            grant.environmentOverrides[
                SteamExternalStorageProcessGrant
                    .manifestSHA256EnvironmentKey
            ],
            grant.manifestSHA256
        )
        XCTAssertEqual(
            grant.environmentOverrides[
                SteamExternalStorageProcessGrant
                    .runIdentifierEnvironmentKey
            ],
            runIdentifier.lowercased()
        )
        XCTAssertEqual(
            grant.environmentOverrides[
                SteamExternalStorageProcessGrant.bridgeEnvironmentKey
            ],
            fixture.bridge.path
        )

        let data = try Data(contentsOf: grant.manifestURL)
        XCTAssertEqual(
            grant.manifestSHA256,
            SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        )
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(document["schema_version"] as? Int, 1)
        XCTAssertEqual(
            document["producer"] as? String,
            "forgeplay-external-storage-grant"
        )
        XCTAssertEqual(
            document["run_identifier"] as? String,
            runIdentifier.lowercased()
        )
        XCTAssertEqual(
            (document["created_at_unix_milliseconds"] as? NSNumber)?
                .int64Value,
            1_800_000_000_125
        )
        let entries = try XCTUnwrap(
            document["entries"] as? [[String: Any]]
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(
            entries[0]["canonical_path"] as? String,
            fixture.externalStorage.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(
            Data(
                base64Encoded:
                    try XCTUnwrap(entries[0]["bookmark_base64"] as? String)
            ),
            Data(
                "implicit-bookmark:\(fixture.externalStorage.resolvingSymlinksInPath().path)"
                    .utf8
            )
        )
        XCTAssertEqual(
            try permissions(at: grant.manifestURL),
            S_IRUSR | S_IWUSR
        )
        XCTAssertEqual(
            try permissions(
                at: grant.manifestURL.deletingLastPathComponent()
            ),
            S_IRWXU
        )
    }

    func testPublisherRejectsMoreThanThirtyTwoRootsBeforeWriting() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let publisher = SteamExternalStorageProcessGrantPublisher(
            fileManager: .default,
            applicationGroupContainerURLProvider: {
                fixture.applicationGroupContainer
            },
            bridgeURLProvider: { fixture.bridge },
            bookmarkDataProvider: { _ in Data("bookmark".utf8) }
        )

        XCTAssertThrowsError(try publisher.publish(
            roots: Array(
                repeating: fixture.externalStorage,
                count:
                    SteamExternalStorageProcessGrantPublisher
                        .maximumRootCount + 1
            ),
            prefix: fixture.prefix,
            runIdentifier: UUID().uuidString
        )) { error in
            guard case SteamExternalStorageProcessGrantError
                .tooManyRoots(let count) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(count, 33)
        }
    }

    func testPublisherRejectsEmptyRootSet() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let publisher = SteamExternalStorageProcessGrantPublisher(
            fileManager: .default,
            applicationGroupContainerURLProvider: {
                fixture.applicationGroupContainer
            },
            bridgeURLProvider: { fixture.bridge },
            bookmarkDataProvider: { _ in Data("bookmark".utf8) }
        )

        XCTAssertThrowsError(try publisher.publish(
            roots: [],
            prefix: fixture.prefix,
            runIdentifier: UUID().uuidString
        )) { error in
            guard case SteamExternalStorageProcessGrantError
                .externalStorageRootRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPublisherRejectsOversizedBookmarkManifest() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let publisher = SteamExternalStorageProcessGrantPublisher(
            fileManager: .default,
            applicationGroupContainerURLProvider: {
                fixture.applicationGroupContainer
            },
            bridgeURLProvider: { fixture.bridge },
            bookmarkDataProvider: { _ in
                Data(
                    repeating: 0xA5,
                    count:
                        SteamExternalStorageProcessGrantPublisher
                            .maximumManifestBytes
                )
            }
        )

        XCTAssertThrowsError(try publisher.publish(
            roots: [fixture.externalStorage],
            prefix: fixture.prefix,
            runIdentifier: UUID().uuidString
        )) { error in
            guard case SteamExternalStorageProcessGrantError
                .manifestTooLarge(let byteCount) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(
                byteCount,
                SteamExternalStorageProcessGrantPublisher
                    .maximumManifestBytes
            )
        }
    }

    func testRemovingEnvironmentStripsOnlyGrantContractKeys() {
        var environment = [
            "WINEPREFIX": "/tmp/Prefix",
            SteamExternalStorageProcessGrant
                .manifestFileEnvironmentKey: "/tmp/grant.json",
            SteamExternalStorageProcessGrant
                .manifestSHA256EnvironmentKey: "abc",
            SteamExternalStorageProcessGrant
                .runIdentifierEnvironmentKey: UUID().uuidString,
            SteamExternalStorageProcessGrant
                .bridgeEnvironmentKey: "/tmp/bridge.dylib"
        ]
        environment = SteamExternalStorageProcessGrant
            .removingEnvironment(from: environment)

        XCTAssertEqual(environment, ["WINEPREFIX": "/tmp/Prefix"])
    }

    func testPublisherBoundsRecentManifestHistoryBeforeCapacityExhaustion()
        throws
    {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let publisher = SteamExternalStorageProcessGrantPublisher(
            fileManager: .default,
            applicationGroupContainerURLProvider: {
                fixture.applicationGroupContainer
            },
            bridgeURLProvider: { fixture.bridge },
            bookmarkDataProvider: { _ in Data("bookmark".utf8) },
            dateProvider: { now }
        )
        let firstGrant = try publisher.publish(
            roots: [fixture.externalStorage],
            prefix: fixture.prefix,
            runIdentifier: UUID().uuidString
        )
        let grantDirectory = firstGrant.manifestURL
            .deletingLastPathComponent()
        var newestHistoricalManifest: URL?
        for index in 0...SteamExternalStorageProcessGrantPublisher
            .maximumRetainedGrantManifests + 8 {
            let manifest = grantDirectory.appending(
                path: "\(UUID().uuidString.lowercased()).json"
            )
            try Data("historical-\(index)".utf8).write(to: manifest)
            try FileManager.default.setAttributes(
                [
                    .modificationDate:
                        now.addingTimeInterval(TimeInterval(index + 1))
                ],
                ofItemAtPath: manifest.path
            )
            newestHistoricalManifest = manifest
        }

        let currentGrant = try publisher.publish(
            roots: [fixture.externalStorage],
            prefix: fixture.prefix,
            runIdentifier: UUID().uuidString
        )
        let retainedManifests = try FileManager.default
            .contentsOfDirectory(
                at: grantDirectory,
                includingPropertiesForKeys: nil
            )
            .filter {
                $0.pathExtension == "json" &&
                    UUID(
                        uuidString: $0.deletingPathExtension()
                            .lastPathComponent
                    ) != nil
            }

        XCTAssertLessThanOrEqual(
            retainedManifests.count,
            SteamExternalStorageProcessGrantPublisher
                .maximumRetainedGrantManifests
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: currentGrant.manifestURL.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try XCTUnwrap(newestHistoricalManifest).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: firstGrant.manifestURL.path
            )
        )
    }

    private func makeFixture() throws -> (
        root: URL,
        applicationGroupContainer: URL,
        externalStorage: URL,
        prefix: URL,
        bridge: URL
    ) {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ForgePlayExternalStorageGrant-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let applicationGroupContainer = root.appending(
            path: "GroupContainer",
            directoryHint: .isDirectory
        )
        let externalStorage = root.appending(
            path: "External/SteamLibrary",
            directoryHint: .isDirectory
        )
        let prefix = root.appending(
            path: "ManagedData/Prefixes/SteamShared",
            directoryHint: .isDirectory
        )
        let bridge = root.appending(
            path: "ForgePlayExternalStorageAccess.dylib",
            directoryHint: .notDirectory
        )
        try FileManager.default.createDirectory(
            at: applicationGroupContainer,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalStorage,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefix,
            withIntermediateDirectories: true
        )
        try Data("bridge".utf8).write(to: bridge)
        return (
            root,
            applicationGroupContainer,
            externalStorage,
            prefix,
            bridge
        )
    }

    private func permissions(at url: URL) throws -> mode_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status.st_mode & mode_t(0o777)
    }
}
