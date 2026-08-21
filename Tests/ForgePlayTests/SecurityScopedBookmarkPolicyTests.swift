import SwiftData
import XCTest
@testable import ForgePlay

@MainActor
final class SecurityScopedBookmarkPolicyTests: XCTestCase {
    func testBundledRuntimeBookmarkCreationUsesReadOnlySecurityScope() {
        let options = SecurityScopedBookmarkPolicy.readOnlyBookmarkCreationOptions

        XCTAssertTrue(options.contains(.withSecurityScope))
        XCTAssertTrue(options.contains(.securityScopeAllowOnlyReadAccess))
    }

    func testExternalStorageBookmarkCreationRemainsReadWrite() {
        let options = SecurityScopedBookmarkPolicy.readWriteBookmarkCreationOptions

        XCTAssertTrue(options.contains(.withSecurityScope))
        XCTAssertFalse(options.contains(.securityScopeAllowOnlyReadAccess))
    }

    func testManagedRuntimeAuthorizationUsesReadOnlyBookmarkCreator() throws {
        let source = try String(
            contentsOf: projectRoot().appending(
                path: "Sources/ForgePlay/UI/SteamCompatibilityLaunchView.swift"
            ),
            encoding: .utf8
        )
        guard let functionStart = source.range(
            of: "private func prepareManagedRuntimeAuthorization()"
        ) else {
            return XCTFail("Managed Runtime authorization function is missing")
        }
        let functionSource = source[functionStart.lowerBound...]

        XCTAssertTrue(
            functionSource.contains(
                "SecurityScopedBookmarkPolicy.readOnlyBookmarkData("
            )
        )
        XCTAssertFalse(
            functionSource.contains(
                "SecurityScopedBookmarkPolicy.bookmarkData("
            )
        )
    }

    func testBookmarkCreationFailureKeepsRolePathAndReason() throws {
        enum BookmarkTestError: LocalizedError {
            case denied

            var errorDescription: String? { "denied by test" }
        }

        let url = URL(fileURLWithPath: "/tmp/ForgePlayBookmarkDenied")

        let result = SecurityScopedBookmarkPolicy.createBookmarkData(
            for: url,
            role: .steamInstaller,
            bookmarkCreator: { _ in throw BookmarkTestError.denied }
        )

        guard case .failure(let failure) = result else {
            return XCTFail("Expected bookmark creation failure, got \(result)")
        }
        XCTAssertEqual(failure.role, .steamInstaller)
        XCTAssertEqual(failure.path, url.path)
        XCTAssertEqual(failure.reason, "denied by test")
    }

    func testMissingBookmarkUsesValidatedLegacyPathFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLegacyRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let resolution = SecurityScopedBookmarkPolicy.resolve(
            path: root.path,
            bookmark: nil,
            role: .selectedRoot
        )

        guard case .pathFallback(let url) = resolution else {
            return XCTFail("Expected legacy path fallback, got \(resolution)")
        }
        XCTAssertEqual(url.standardizedFileURL.path, root.standardizedFileURL.path)
    }

    func testMissingBookmarkRejectsInvalidLegacyPathFallback() {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMissingLegacyRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
            .path

        let resolution = SecurityScopedBookmarkPolicy.resolve(
            path: path,
            bookmark: nil,
            role: .selectedRoot
        )

        guard case .unavailable(let failure) = resolution else {
            return XCTFail("Expected unavailable invalid fallback, got \(resolution)")
        }
        XCTAssertEqual(failure.role, .selectedRoot)
        XCTAssertEqual(failure.savedPath, path)
    }

    func testInvalidStoredBookmarkDoesNotUsePathOnlyFallback() {
        let resolution = SecurityScopedBookmarkPolicy.resolve(
            path: "/tmp/ForgePlayPreviouslySelected",
            bookmark: Data([0, 1, 2, 3]),
            role: .selectedRoot
        )

        guard case .unavailable(let failure) = resolution else {
            return XCTFail("Expected unavailable bookmark, got \(resolution)")
        }
        XCTAssertEqual(failure.role, .selectedRoot)
        XCTAssertEqual(failure.savedPath, "/tmp/ForgePlayPreviouslySelected")
    }

    func testInvalidStoredBookmarkFallsBackToValidatedPathWhenAllowed() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayBookmarkFallback-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let resolution = SecurityScopedBookmarkPolicy.resolve(
            path: root.path,
            bookmark: Data([0, 1, 2, 3]),
            role: .selectedRoot
        )

        guard case .pathFallback(let url) = resolution else {
            return XCTFail("Expected validated path fallback, got \(resolution)")
        }
        XCTAssertEqual(url.standardizedFileURL.path, root.standardizedFileURL.path)
    }

    func testInvalidStoredBookmarkDoesNotFallBackToPathWhenDisallowed() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayBookmarkNoFallback-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let resolution = SecurityScopedBookmarkPolicy.resolve(
            path: root.path,
            bookmark: Data([0, 1, 2, 3]),
            role: .selectedRoot,
            allowsPathFallback: false
        )

        guard case .unavailable(let failure) = resolution else {
            return XCTFail("Expected unavailable bookmark without fallback, got \(resolution)")
        }
        XCTAssertEqual(failure.role, .selectedRoot)
        XCTAssertEqual(failure.savedPath, root.path)
    }

    func testResolvedBookmarkMustStartSecurityScope() {
        let bookmark = Data("bookmark".utf8)
        let url = URL(fileURLWithPath: "/tmp/ForgePlayBookmarkNoScope")

        let resolution = SecurityScopedBookmarkPolicy.resolve(
            path: url.path,
            bookmark: bookmark,
            role: .selectedRoot,
            bookmarkResolver: { data in
                XCTAssertEqual(data, bookmark)
                return SecurityScopedBookmarkResolvedURL(url: url, isStale: false)
            },
            securityScopeStarter: { startedURL in
                XCTAssertEqual(startedURL.path, url.path)
                return false
            }
        )

        guard case .unavailable(let failure) = resolution else {
            return XCTFail("Expected unavailable bookmark when security scope cannot start, got \(resolution)")
        }
        XCTAssertEqual(failure.role, .selectedRoot)
        XCTAssertEqual(failure.savedPath, url.path)
        XCTAssertEqual(failure.reason, "security-scoped resource access could not be started")
    }

    func testResolvedBookmarkScopeFailureDoesNotFallbackToExistingPathWhenDisallowed() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayBookmarkExistingNoScope-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bookmark = Data("bookmark".utf8)

        let resolution = SecurityScopedBookmarkPolicy.resolve(
            path: root.path,
            bookmark: bookmark,
            role: .selectedRoot,
            allowsPathFallback: false,
            bookmarkResolver: { data in
                XCTAssertEqual(data, bookmark)
                return SecurityScopedBookmarkResolvedURL(url: root, isStale: false)
            },
            securityScopeStarter: { startedURL in
                XCTAssertEqual(startedURL.standardizedFileURL.path, root.standardizedFileURL.path)
                return false
            }
        )

        guard case .unavailable(let failure) = resolution else {
            return XCTFail("Expected unavailable bookmark when scope fails in sandbox policy, got \(resolution)")
        }
        XCTAssertEqual(failure.role, .selectedRoot)
        XCTAssertEqual(failure.savedPath, root.path)
        XCTAssertEqual(failure.reason, "security-scoped resource access could not be started")
    }

    func testResolvedBookmarkRetainsStartedSecurityScope() {
        let bookmark = Data("bookmark".utf8)
        let url = URL(fileURLWithPath: "/tmp/ForgePlayBookmarkWithScope")

        let resolution = SecurityScopedBookmarkPolicy.resolve(
            path: url.path,
            bookmark: bookmark,
            role: .selectedRoot,
            bookmarkResolver: { data in
                XCTAssertEqual(data, bookmark)
                return SecurityScopedBookmarkResolvedURL(url: url, isStale: true)
            },
            securityScopeStarter: { startedURL in
                XCTAssertEqual(startedURL.path, url.path)
                return true
            }
        )

        guard case .restored(let access) = resolution else {
            return XCTFail("Expected restored bookmark, got \(resolution)")
        }
        XCTAssertEqual(access.url.path, url.path)
        XCTAssertTrue(access.isStale)
        XCTAssertTrue(access.didStartSecurityScope)
    }

    func testSteamLibraryBookmarkRestoresExternalRootAcrossAppSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalSteamLibrary-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bookmark = Data("steam-library-bookmark".utf8)
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let record = SteamGameRecord(
            steamAppId: "10",
            name: "Test Game",
            installDir: "TestGame",
            libraryPath: root.path,
            manifestPath: root.appending(path: "steamapps/appmanifest_10.acf").path,
            libraryBookmark: bookmark
        )
        context.insert(record)
        try context.save()

        let appState = AppState()
        let restored = appState.restoredSteamLibraryRoots(
            from: [record],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { data in
                XCTAssertEqual(data, bookmark)
                return SecurityScopedBookmarkResolvedURL(url: root, isStale: false)
            },
            securityScopeStarter: { url in
                XCTAssertEqual(url.standardizedFileURL.path, root.standardizedFileURL.path)
                return true
            }
        )

        XCTAssertEqual(restored.map(\.standardizedFileURL.path), [root.standardizedFileURL.path])
        XCTAssertNil(appState.currentNotice)
    }

    func testLegacyGameBookmarkMigratesToPersistentSteamStorageMount() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLegacySteamBookmark-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bookmark = Data("legacy-steam-library-bookmark".utf8)
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let game = SteamGameRecord(
            steamAppId: "11",
            name: "Legacy Game",
            installDir: "LegacyGame",
            libraryPath: root.path,
            manifestPath: root.appending(path: "steamapps/appmanifest_11.acf").path,
            libraryBookmark: bookmark
        )
        context.insert(game)
        try context.save()

        let appState = AppState()
        let restored = appState.restoreSteamStorageAccess(
            from: [],
            legacyGameRecords: [game],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { data in
                XCTAssertEqual(data, bookmark)
                return SecurityScopedBookmarkResolvedURL(url: root, isStale: false)
            },
            securityScopeStarter: { url in
                XCTAssertEqual(url.standardizedFileURL.path, root.standardizedFileURL.path)
                return true
            }
        )

        XCTAssertEqual(restored.roots.map(\.path), [root.standardizedFileURL.path])
        let mounts = try context.fetch(FetchDescriptor<SteamStorageMountRecord>())
        XCTAssertEqual(mounts.count, 1)
        XCTAssertEqual(mounts.first?.path, root.standardizedFileURL.path)
        XCTAssertEqual(mounts.first?.bookmark, bookmark)
    }

    func testAncestorStorageMountOwnsNestedLegacyLibraryWithoutDuplicateMount() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlayAncestorSteamStorage-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let authorizedRoot = temporaryRoot.appending(
            path: "ExternalVolume",
            directoryHint: .isDirectory
        )
        let nestedLibrary = authorizedRoot.appending(
            path: "SteamLibrary",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: nestedLibrary,
            withIntermediateDirectories: true
        )

        let mountBookmark = Data("ancestor-storage-bookmark".utf8)
        let legacyBookmark = Data("nested-legacy-bookmark".utf8)
        let container = try ForgePlayApp.makeModelContainer(
            isStoredInMemoryOnly: true
        )
        let context = container.mainContext
        let mount = SteamStorageMountRecord(
            path: authorizedRoot.path,
            bookmark: mountBookmark
        )
        let game = SteamGameRecord(
            steamAppId: "ancestor-owned-game",
            name: "Ancestor Owned Game",
            installDir: "AncestorOwnedGame",
            libraryPath: nestedLibrary.path,
            manifestPath: nestedLibrary
                .appending(path: "steamapps/appmanifest_ancestor.acf")
                .path,
            libraryBookmark: legacyBookmark
        )
        context.insert(mount)
        context.insert(game)
        try context.save()

        var resolvedBookmarks: [Data] = []
        let appState = AppState()
        let restoration = appState.restoreSteamStorageAccess(
            from: [mount],
            legacyGameRecords: [game],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { bookmark in
                resolvedBookmarks.append(bookmark)
                XCTAssertEqual(bookmark, mountBookmark)
                return SecurityScopedBookmarkResolvedURL(
                    url: authorizedRoot,
                    isStale: false
                )
            },
            securityScopeStarter: { _ in true }
        )

        XCTAssertEqual(resolvedBookmarks, [mountBookmark])
        XCTAssertEqual(
            restoration.roots.map(\.path),
            [authorizedRoot.standardizedFileURL.path]
        )
        XCTAssertEqual(
            restoration.driveReservationRoots.map(\.path),
            [authorizedRoot.standardizedFileURL.path]
        )
        XCTAssertEqual(restoration.unavailableCount, 0)
        let mounts = try context.fetch(
            FetchDescriptor<SteamStorageMountRecord>()
        )
        XCTAssertEqual(mounts.count, 1)
        XCTAssertEqual(mounts.first?.path, authorizedRoot.standardizedFileURL.path)
        XCTAssertEqual(game.libraryBookmark, legacyBookmark)
    }

    func testCanonicalAliasLegacyLibraryUsesExistingStorageAuthorization() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlayCanonicalSteamStorage-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let authorizedRoot = temporaryRoot.appending(
            path: "SteamLibrary",
            directoryHint: .isDirectory
        )
        let aliasRoot = temporaryRoot.appending(
            path: "SteamLibrary-Alias",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: authorizedRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: aliasRoot,
            withDestinationURL: authorizedRoot
        )

        let mountBookmark = Data("canonical-storage-bookmark".utf8)
        let legacyBookmark = Data("canonical-legacy-bookmark".utf8)
        let container = try ForgePlayApp.makeModelContainer(
            isStoredInMemoryOnly: true
        )
        let context = container.mainContext
        let mount = SteamStorageMountRecord(
            path: authorizedRoot.path,
            bookmark: mountBookmark
        )
        let game = SteamGameRecord(
            steamAppId: "canonical-alias-game",
            name: "Canonical Alias Game",
            installDir: "CanonicalAliasGame",
            libraryPath: aliasRoot.path,
            manifestPath: aliasRoot
                .appending(path: "steamapps/appmanifest_alias.acf")
                .path,
            libraryBookmark: legacyBookmark
        )
        context.insert(mount)
        context.insert(game)
        try context.save()

        var resolvedBookmarks: [Data] = []
        let appState = AppState()
        let restoration = appState.restoreSteamStorageAccess(
            from: [mount],
            legacyGameRecords: [game],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { bookmark in
                resolvedBookmarks.append(bookmark)
                XCTAssertEqual(bookmark, mountBookmark)
                return SecurityScopedBookmarkResolvedURL(
                    url: authorizedRoot,
                    isStale: false
                )
            },
            securityScopeStarter: { _ in true }
        )

        XCTAssertEqual(resolvedBookmarks, [mountBookmark])
        XCTAssertEqual(
            restoration.roots.map(\.path),
            [authorizedRoot.standardizedFileURL.path]
        )
        XCTAssertEqual(
            try context.fetch(
                FetchDescriptor<SteamStorageMountRecord>()
            ).map(\.path),
            [authorizedRoot.standardizedFileURL.path]
        )
    }

    func testSiblingStorageMountAndLegacyLibraryRemainIndependentRoots() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "ForgePlaySiblingSteamStorage-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let mountedLibrary = temporaryRoot.appending(
            path: "SteamLibrary-A",
            directoryHint: .isDirectory
        )
        let legacyLibrary = temporaryRoot.appending(
            path: "SteamLibrary-B",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: mountedLibrary,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: legacyLibrary,
            withIntermediateDirectories: true
        )

        let mountBookmark = Data("sibling-mount-bookmark".utf8)
        let legacyBookmark = Data("sibling-legacy-bookmark".utf8)
        let container = try ForgePlayApp.makeModelContainer(
            isStoredInMemoryOnly: true
        )
        let context = container.mainContext
        let mount = SteamStorageMountRecord(
            path: mountedLibrary.path,
            bookmark: mountBookmark
        )
        let game = SteamGameRecord(
            steamAppId: "sibling-legacy-game",
            name: "Sibling Legacy Game",
            installDir: "SiblingLegacyGame",
            libraryPath: legacyLibrary.path,
            manifestPath: legacyLibrary
                .appending(path: "steamapps/appmanifest_sibling.acf")
                .path,
            libraryBookmark: legacyBookmark
        )
        context.insert(mount)
        context.insert(game)
        try context.save()

        var resolvedBookmarks = Set<Data>()
        let appState = AppState()
        let restoration = appState.restoreSteamStorageAccess(
            from: [mount],
            legacyGameRecords: [game],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { bookmark in
                resolvedBookmarks.insert(bookmark)
                if bookmark == mountBookmark {
                    return SecurityScopedBookmarkResolvedURL(
                        url: mountedLibrary,
                        isStale: false
                    )
                }
                if bookmark == legacyBookmark {
                    return SecurityScopedBookmarkResolvedURL(
                        url: legacyLibrary,
                        isStale: false
                    )
                }
                throw CocoaError(.fileReadCorruptFile)
            },
            securityScopeStarter: { _ in true }
        )

        let expectedPaths = [
            mountedLibrary.standardizedFileURL.path,
            legacyLibrary.standardizedFileURL.path
        ].sorted()
        XCTAssertEqual(resolvedBookmarks, Set([mountBookmark, legacyBookmark]))
        XCTAssertEqual(restoration.roots.map(\.path), expectedPaths)
        XCTAssertEqual(
            restoration.driveReservationRoots.map(\.path),
            expectedPaths
        )
        XCTAssertEqual(restoration.unavailableCount, 0)
        let mountPaths = try context.fetch(
            FetchDescriptor<SteamStorageMountRecord>()
        ).map(\.path).sorted()
        XCTAssertEqual(mountPaths, expectedPaths)
    }

    func testInvalidMountBookmarkFallsBackToAnotherLegacyBookmarkAndRepairsPersistedAccess() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLegacyBookmarkFallback-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalidBookmark = Data("invalid-steam-library-bookmark".utf8)
        let validBookmark = Data("valid-steam-library-bookmark".utf8)
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let invalidGame = SteamGameRecord(
            steamAppId: "12",
            name: "Legacy Game A",
            installDir: "LegacyGameA",
            libraryPath: root.path,
            manifestPath: root.appending(path: "steamapps/appmanifest_12.acf").path,
            libraryBookmark: invalidBookmark
        )
        let validGame = SteamGameRecord(
            steamAppId: "13",
            name: "Legacy Game B",
            installDir: "LegacyGameB",
            libraryPath: root.path,
            manifestPath: root.appending(path: "steamapps/appmanifest_13.acf").path,
            libraryBookmark: validBookmark
        )
        let mount = SteamStorageMountRecord(path: root.path, bookmark: invalidBookmark)
        context.insert(invalidGame)
        context.insert(validGame)
        context.insert(mount)
        try context.save()

        var resolvedBookmarks: [Data] = []
        let appState = AppState()
        let restoration = appState.restoreSteamStorageAccess(
            from: [mount],
            legacyGameRecords: [invalidGame, validGame],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { bookmark in
                resolvedBookmarks.append(bookmark)
                guard bookmark == validBookmark else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return SecurityScopedBookmarkResolvedURL(url: root, isStale: false)
            },
            securityScopeStarter: { url in
                XCTAssertEqual(url.standardizedFileURL.path, root.standardizedFileURL.path)
                return true
            }
        )

        XCTAssertEqual(resolvedBookmarks, [invalidBookmark, invalidBookmark, validBookmark])
        XCTAssertEqual(restoration.roots.map(\.standardizedFileURL.path), [root.standardizedFileURL.path])
        XCTAssertEqual(restoration.unavailableCount, 0)
        XCTAssertFalse(restoration.bookmarkPersistenceFailed)
        XCTAssertNil(appState.currentNotice)
        XCTAssertEqual(invalidGame.libraryBookmark, validBookmark)
        XCTAssertEqual(validGame.libraryBookmark, validBookmark)
        XCTAssertEqual(mount.bookmark, validBookmark)
    }

    func testDuplicateSteamStorageMountsTryEveryBookmarkAndMergeTheValidCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayDuplicateSteamMount-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalidBookmark = Data("invalid-duplicate-mount-bookmark".utf8)
        let validBookmark = Data("valid-duplicate-mount-bookmark".utf8)
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let invalidMount = SteamStorageMountRecord(path: root.path, bookmark: invalidBookmark)
        let validMount = SteamStorageMountRecord(path: root.path, bookmark: validBookmark)
        validMount.path = root.path + "/."
        context.insert(invalidMount)
        context.insert(validMount)
        try context.save()

        var resolvedBookmarks: [Data] = []
        let appState = AppState()
        let restoration = appState.restoreSteamStorageMountAccess(
            from: [invalidMount, validMount],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { bookmark in
                resolvedBookmarks.append(bookmark)
                guard bookmark == validBookmark else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return SecurityScopedBookmarkResolvedURL(url: root, isStale: false)
            },
            securityScopeStarter: { _ in true }
        )

        XCTAssertEqual(resolvedBookmarks, [invalidBookmark, validBookmark])
        XCTAssertEqual(restoration.roots.map(\.standardizedFileURL.path), [root.standardizedFileURL.path])
        XCTAssertEqual(restoration.unavailableCount, 0)
        XCTAssertFalse(restoration.bookmarkPersistenceFailed)
        XCTAssertEqual(invalidMount.bookmark, validBookmark)
        XCTAssertEqual(validMount.bookmark, validBookmark)
    }

    func testDisconnectingSteamStorageMountClearsLegacyBookmarksAndPreventsRecreation() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayDisconnectedSteamMount-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let mountedRoot = root.appending(path: "SteamStorage", directoryHint: .isDirectory)
        let nestedLibrary = mountedRoot.appending(path: "SteamLibrary", directoryHint: .isDirectory)
        let siblingLibrary = root.appending(path: "SteamStorage-Archive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nestedLibrary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingLibrary, withIntermediateDirectories: true)
        let bookmark = Data("disconnected-steam-mount-bookmark".utf8)
        let siblingBookmark = Data("sibling-steam-mount-bookmark".utf8)
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let game = SteamGameRecord(
            steamAppId: "14",
            name: "Disconnected Legacy Game",
            installDir: "DisconnectedLegacyGame",
            libraryPath: nestedLibrary.path + "/.",
            manifestPath: nestedLibrary.appending(path: "steamapps/appmanifest_14.acf").path,
            libraryBookmark: bookmark
        )
        let siblingGame = SteamGameRecord(
            steamAppId: "15",
            name: "Sibling Legacy Game",
            installDir: "SiblingLegacyGame",
            libraryPath: siblingLibrary.path,
            manifestPath: siblingLibrary.appending(path: "steamapps/appmanifest_15.acf").path,
            libraryBookmark: siblingBookmark
        )
        let mount = SteamStorageMountRecord(path: mountedRoot.path, bookmark: bookmark)
        context.insert(game)
        context.insert(siblingGame)
        context.insert(mount)
        try context.save()

        let appState = AppState()
        let initialRestoration = appState.restoreSteamStorageMountAccess(
            from: [mount],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { _ in
                SecurityScopedBookmarkResolvedURL(url: mountedRoot, isStale: false)
            },
            securityScopeStarter: { _ in true }
        )
        XCTAssertEqual(initialRestoration.roots.map(\.path), [mountedRoot.standardizedFileURL.path])
        XCTAssertEqual(
            appState.retainedSteamLibrarySecurityScopedPathsForTesting,
            [mountedRoot.standardizedFileURL.path]
        )

        try appState.disconnectSteamStorageMount(mount, in: context)

        XCTAssertNil(game.libraryBookmark)
        XCTAssertEqual(siblingGame.libraryBookmark, siblingBookmark)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SteamStorageMountRecord>()).isEmpty)
        XCTAssertTrue(appState.retainedSteamLibrarySecurityScopedPathsForTesting.isEmpty)
        let restoration = appState.restoreSteamStorageAccess(
            from: [],
            legacyGameRecords: [game],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { _ in
                XCTFail("A disconnected legacy bookmark must not be resolved again")
                throw CocoaError(.fileReadNoSuchFile)
            },
            securityScopeStarter: { _ in true }
        )

        XCTAssertTrue(restoration.roots.isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SteamStorageMountRecord>()).isEmpty)
    }

    func testDisconnectSteamStorageMountSaveFailureRestoresModelsAndPreservesLease() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayDisconnectRollback-\(UUID().uuidString)", directoryHint: .isDirectory)
        let library = root.appending(path: "SteamLibrary", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let bookmark = Data("disconnect-rollback-bookmark".utf8)
        let mount = SteamStorageMountRecord(path: root.path, bookmark: bookmark)
        let game = SteamGameRecord(
            steamAppId: "16",
            name: "Disconnect Rollback Game",
            installDir: "DisconnectRollbackGame",
            libraryPath: library.path,
            manifestPath: library.appending(path: "steamapps/appmanifest_16.acf").path,
            libraryBookmark: bookmark
        )
        context.insert(mount)
        context.insert(game)
        try context.save()

        let appState = AppState()
        _ = appState.restoreSteamStorageMountAccess(
            from: [mount],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { _ in
                SecurityScopedBookmarkResolvedURL(url: root, isStale: false)
            },
            securityScopeStarter: { _ in true }
        )

        XCTAssertThrowsError(
            try appState.disconnectSteamStorageMount(
                mount,
                in: context,
                saveChanges: { _ in throw CocoaError(.fileWriteNoPermission) }
            )
        )

        XCTAssertEqual(game.libraryBookmark, bookmark)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SteamStorageMountRecord>()).map(\.id), [mount.id])
        XCTAssertEqual(
            appState.retainedSteamLibrarySecurityScopedPathsForTesting,
            [root.standardizedFileURL.path]
        )
        let verificationContext = ModelContext(container)
        XCTAssertEqual(
            try verificationContext.fetch(FetchDescriptor<SteamStorageMountRecord>()).first?.bookmark,
            bookmark
        )
        appState.releaseAllSecurityScopedAccess()
    }

    func testEmptySteamStorageMountRestoresWithoutGameRecords() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayEmptySteamStorage-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bookmark = Data("steam-storage-bookmark".utf8)
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let record = try context.upsertSteamStorageMount(url: root, bookmark: bookmark)
        try context.save()

        let appState = AppState()
        let restored = appState.restoreSteamStorageMountAccess(
            from: [record],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { data in
                XCTAssertEqual(data, bookmark)
                return SecurityScopedBookmarkResolvedURL(url: root, isStale: false)
            },
            securityScopeStarter: { url in
                XCTAssertEqual(url.standardizedFileURL.path, root.standardizedFileURL.path)
                return true
            }
        )

        XCTAssertEqual(restored.roots.map(\.standardizedFileURL.path), [root.standardizedFileURL.path])
        XCTAssertEqual(restored.unavailableCount, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SteamGameRecord>()).isEmpty)
    }

    func testPersistedSteamStorageRestorationFetchesRecordsAtOperationTime() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayFreshSteamStorage-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let staleMountSnapshot = try context.fetch(FetchDescriptor<SteamStorageMountRecord>())
        let staleGameSnapshot = try context.fetch(FetchDescriptor<SteamGameRecord>())
        XCTAssertTrue(staleMountSnapshot.isEmpty)
        XCTAssertTrue(staleGameSnapshot.isEmpty)

        let bookmark = Data("fresh-operation-bookmark".utf8)
        context.insert(SteamStorageMountRecord(path: root.path, bookmark: bookmark))
        context.insert(SteamGameRecord(
            steamAppId: "7788",
            name: "Fresh Storage Game",
            installDir: "FreshStorageGame",
            libraryPath: root.path,
            manifestPath: root.appending(path: "steamapps/appmanifest_7788.acf").path
        ))
        try context.save()

        let appState = AppState()
        let restoration = try appState.restorePersistedSteamStorageAccess(
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { data in
                XCTAssertEqual(data, bookmark)
                return SecurityScopedBookmarkResolvedURL(url: root, isStale: false)
            },
            securityScopeStarter: { _ in true }
        )

        XCTAssertEqual(restoration.roots.map(\.path), [root.standardizedFileURL.path])
        XCTAssertEqual(restoration.sourceGameRecordCount, 1)
        XCTAssertEqual(restoration.unavailableCount, 0)
        appState.releaseAllSecurityScopedAccess()
    }

    func testSteamStorageConnectionOperationIsOwnedAndSerializedByAppState() async {
        let appState = AppState()
        let gate = SteamStorageConnectionOperationGate()

        XCTAssertTrue(appState.beginSteamStorageConnectionOperation(id: "first") {
            await gate.wait()
        })
        XCTAssertEqual(appState.steamStorageOperationMountID, "first")
        XCTAssertFalse(appState.beginSteamStorageConnectionOperation(id: "second") {})

        await gate.open()
        for _ in 0..<20 where appState.steamStorageOperationMountID != nil {
            await Task.yield()
        }

        XCTAssertNil(appState.steamStorageOperationMountID)
    }

    func testPersistentSettingsReloadPreservesSteamStorageSecurityScopeLease() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRetainedSteamStorage-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let bookmark = Data("retained-steam-storage-bookmark".utf8)
        let record = SteamStorageMountRecord(path: root.path, bookmark: bookmark)
        context.insert(record)
        try context.save()

        let appState = AppState()
        let restoration = appState.restoreSteamStorageMountAccess(
            from: [record],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { data in
                XCTAssertEqual(data, bookmark)
                return SecurityScopedBookmarkResolvedURL(url: root, isStale: false)
            },
            securityScopeStarter: { _ in true }
        )
        XCTAssertEqual(restoration.roots.map(\.path), [root.standardizedFileURL.path])
        XCTAssertEqual(
            appState.retainedSteamLibrarySecurityScopedPathsForTesting,
            [root.standardizedFileURL.path]
        )

        try appState.load(from: context)

        XCTAssertEqual(
            appState.retainedSteamLibrarySecurityScopedPathsForTesting,
            [root.standardizedFileURL.path]
        )
        appState.releaseAllSecurityScopedAccess()
    }

    func testAncestorBookmarkRestoresNestedSteamStorageMountPath() throws {
        let authorizedRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayAuthorizedRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        let steamRoot = authorizedRoot.appending(path: "SteamLibrary", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: authorizedRoot) }
        try FileManager.default.createDirectory(at: steamRoot, withIntermediateDirectories: true)
        let bookmark = Data("ancestor-bookmark".utf8)
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let record = SteamStorageMountRecord(path: steamRoot.path, bookmark: bookmark)
        context.insert(record)
        try context.save()

        let appState = AppState()
        let restored = appState.restoreSteamStorageMountAccess(
            from: [record],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { data in
                XCTAssertEqual(data, bookmark)
                return SecurityScopedBookmarkResolvedURL(url: authorizedRoot, isStale: false)
            },
            securityScopeStarter: { url in
                XCTAssertEqual(url.standardizedFileURL.path, authorizedRoot.standardizedFileURL.path)
                return true
            }
        )

        XCTAssertEqual(restored.roots.map(\.path), [steamRoot.path])
        XCTAssertEqual(record.path, steamRoot.path)
        XCTAssertEqual(restored.unavailableCount, 0)
    }

    func testNonStaleMovedBookmarkPersistsResolvedPathAndRekeysRetainedAccess() throws {
        let savedRoot = URL(fileURLWithPath: "/Volumes/Previous/SteamLibrary", isDirectory: true)
        let resolvedRoot = URL(fileURLWithPath: "/Volumes/Current/SteamLibrary", isDirectory: true)
        let bookmark = Data("moved-bookmark".utf8)
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let record = SteamStorageMountRecord(path: savedRoot.path, bookmark: bookmark)
        context.insert(record)
        try context.save()

        let appState = AppState()
        let restoration = appState.restoreSteamStorageMountAccess(
            from: [record],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { _ in
                SecurityScopedBookmarkResolvedURL(url: resolvedRoot, isStale: false)
            },
            securityScopeStarter: { _ in true }
        )

        XCTAssertEqual(restoration.roots.map(\.path), [resolvedRoot.standardizedFileURL.path])
        XCTAssertEqual(
            restoration.driveReservationRoots.map(\.path),
            [resolvedRoot.standardizedFileURL.path]
        )
        XCTAssertEqual(record.path, resolvedRoot.standardizedFileURL.path)
        XCTAssertEqual(
            appState.retainedSteamLibrarySecurityScopedPathsForTesting,
            [resolvedRoot.standardizedFileURL.path]
        )

        appState.releaseSteamStorageSecurityScopedAccess(for: record.url)
        XCTAssertTrue(appState.retainedSteamLibrarySecurityScopedPathsForTesting.isEmpty)
    }

    func testReconnectSteamStorageMountRebasesNestedReferencesAndMergesExactPathDuplicates() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayReconnectMount-\(UUID().uuidString)", directoryHint: .isDirectory)
        let oldRoot = root.appending(path: "Old", directoryHint: .isDirectory)
        let newRoot = root.appending(path: "New", directoryHint: .isDirectory)
        let siblingRoot = root.appending(path: "Old-Archive", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingRoot, withIntermediateDirectories: true)

        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let oldestDate = Date(timeIntervalSince1970: 100)
        let primary = SteamStorageMountRecord(
            path: oldRoot.path,
            bookmark: Data("old-primary".utf8),
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let duplicateOld = SteamStorageMountRecord(
            path: oldRoot.path,
            bookmark: Data("old-duplicate".utf8),
            createdAt: oldestDate
        )
        duplicateOld.path += "/."
        let duplicateNew = SteamStorageMountRecord(
            path: newRoot.path,
            bookmark: Data("new-duplicate".utf8)
        )
        let nestedLibrary = oldRoot.appending(path: "SteamLibrary", directoryHint: .isDirectory)
        let nestedGame = SteamGameRecord(
            steamAppId: "31",
            name: "Moved Game",
            installDir: "MovedGame",
            libraryPath: nestedLibrary.path,
            manifestPath: nestedLibrary.appending(path: "steamapps/appmanifest_31.acf").path,
            libraryBookmark: Data("legacy-bookmark".utf8)
        )
        let siblingGame = SteamGameRecord(
            steamAppId: "32",
            name: "Sibling Game",
            installDir: "SiblingGame",
            libraryPath: siblingRoot.path,
            manifestPath: siblingRoot.appending(path: "steamapps/appmanifest_32.acf").path,
            libraryBookmark: Data("sibling-bookmark".utf8)
        )
        [primary, duplicateOld, duplicateNew].forEach(context.insert)
        context.insert(nestedGame)
        context.insert(siblingGame)
        try context.save()

        let newBookmark = Data("reconnected-bookmark".utf8)
        let reconnectDate = Date(timeIntervalSince1970: 500)
        let appState = AppState()
        _ = try appState.reconnectSteamStorageMount(
            primary,
            to: SteamStorageSelectionAuthorization(root: newRoot, bookmark: newBookmark),
            in: context,
            now: reconnectDate
        )

        let mounts = try context.fetch(FetchDescriptor<SteamStorageMountRecord>())
        XCTAssertEqual(mounts.count, 1)
        XCTAssertEqual(mounts.first?.id, primary.id)
        XCTAssertEqual(mounts.first?.path, newRoot.standardizedFileURL.path)
        XCTAssertEqual(mounts.first?.bookmark, newBookmark)
        XCTAssertEqual(mounts.first?.createdAt, oldestDate)
        XCTAssertEqual(mounts.first?.updatedAt, reconnectDate)
        XCTAssertEqual(
            nestedGame.libraryPath,
            newRoot.appending(path: "SteamLibrary", directoryHint: .isDirectory).path
        )
        XCTAssertEqual(
            nestedGame.manifestPath,
            newRoot.appending(path: "SteamLibrary/steamapps/appmanifest_31.acf").path
        )
        XCTAssertNil(nestedGame.libraryBookmark)
        XCTAssertEqual(siblingGame.libraryPath, siblingRoot.path)
        XCTAssertEqual(siblingGame.libraryBookmark, Data("sibling-bookmark".utf8))
    }

    func testConnectSteamStorageMountMergesExactPathDuplicates() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayConnectDuplicate-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let oldestDate = Date(timeIntervalSince1970: 10)
        let first = SteamStorageMountRecord(
            path: root.path,
            bookmark: Data("first".utf8),
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let duplicate = SteamStorageMountRecord(
            path: root.path,
            bookmark: Data("duplicate".utf8),
            createdAt: oldestDate
        )
        duplicate.path += "/."
        context.insert(first)
        context.insert(duplicate)
        try context.save()

        let newBookmark = Data("connected".utf8)
        let appState = AppState()
        _ = try appState.connectSteamStorageMount(
            SteamStorageSelectionAuthorization(root: root, bookmark: newBookmark),
            in: context
        )

        let mounts = try context.fetch(FetchDescriptor<SteamStorageMountRecord>())
        XCTAssertEqual(mounts.count, 1)
        XCTAssertEqual(mounts.first?.path, root.standardizedFileURL.path)
        XCTAssertEqual(mounts.first?.bookmark, newBookmark)
        XCTAssertEqual(mounts.first?.createdAt, oldestDate)
    }

    func testConnectSteamStorageMountSaveFailureRemovesNewRecordAndDoesNotRetainLease() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayConnectRollback-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let appState = AppState()

        XCTAssertThrowsError(
            try appState.connectSteamStorageMount(
                SteamStorageSelectionAuthorization(
                    root: root,
                    bookmark: Data("new-record-bookmark".utf8)
                ),
                in: context,
                saveChanges: { _ in throw CocoaError(.fileWriteNoPermission) }
            )
        )

        XCTAssertTrue(try context.fetch(FetchDescriptor<SteamStorageMountRecord>()).isEmpty)
        XCTAssertTrue(appState.retainedSteamLibrarySecurityScopedPathsForTesting.isEmpty)
        let verificationContext = ModelContext(container)
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<SteamStorageMountRecord>()).isEmpty)
    }

    func testConnectSteamStorageMountRejectsSaveWithoutPersistentReadback() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayConnectReadback-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let appState = AppState()

        XCTAssertThrowsError(
            try appState.connectSteamStorageMount(
                SteamStorageSelectionAuthorization(
                    root: root,
                    bookmark: Data("readback-bookmark".utf8)
                ),
                in: context,
                saveChanges: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? SteamStorageMountMutationError,
                .persistenceVerificationFailed(root.standardizedFileURL.path)
            )
        }

        XCTAssertTrue(try context.fetch(FetchDescriptor<SteamStorageMountRecord>()).isEmpty)
        XCTAssertTrue(appState.retainedSteamLibrarySecurityScopedPathsForTesting.isEmpty)
    }

    func testConnectNewSteamStorageMountVerificationFailureRemovesStaleRecord() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayConnectNewCompensation-\(UUID().uuidString)", directoryHint: .isDirectory)
        let corruptedRoot = root.appending(path: "Corrupted", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: corruptedRoot,
            withIntermediateDirectories: true
        )

        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let appState = AppState()

        XCTAssertThrowsError(
            try appState.connectSteamStorageMount(
                SteamStorageSelectionAuthorization(
                    root: root,
                    bookmark: Data("new-compensation-bookmark".utf8)
                ),
                in: context,
                saveChanges: { mutationContext in
                    try mutationContext.save()
                    let corruptionContext = ModelContext(container)
                    let persisted = try XCTUnwrap(
                        corruptionContext.fetch(
                            FetchDescriptor<SteamStorageMountRecord>()
                        ).first
                    )
                    persisted.path = corruptedRoot.path
                    try corruptionContext.save()
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? SteamStorageMountMutationError,
                .persistenceVerificationFailed(root.standardizedFileURL.path)
            )
        }

        XCTAssertTrue(
            try context.fetch(FetchDescriptor<SteamStorageMountRecord>()).isEmpty
        )
        let verificationContext = ModelContext(container)
        XCTAssertTrue(
            try verificationContext.fetch(
                FetchDescriptor<SteamStorageMountRecord>()
            ).isEmpty
        )
        XCTAssertTrue(appState.retainedSteamLibrarySecurityScopedPathsForTesting.isEmpty)
    }

    func testConnectSteamStorageMountVerificationFailureRestoresPersistedSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayConnectCompensation-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let first = SteamStorageMountRecord(
            id: "connect-compensation-first",
            path: root.path,
            bookmark: Data("first-bookmark".utf8),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let duplicate = SteamStorageMountRecord(
            id: "connect-compensation-duplicate",
            path: root.path,
            bookmark: Data("duplicate-bookmark".utf8),
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 40)
        )
        duplicate.path += "/."
        let firstID = first.id
        let duplicateID = duplicate.id
        let duplicatePath = duplicate.path
        context.insert(first)
        context.insert(duplicate)
        try context.save()

        let appState = AppState()
        XCTAssertThrowsError(
            try appState.connectSteamStorageMount(
                SteamStorageSelectionAuthorization(
                    root: root,
                    bookmark: Data("replacement-bookmark".utf8)
                ),
                in: context,
                saveChanges: { mutationContext in
                    try mutationContext.save()
                    let corruptionContext = ModelContext(container)
                    let persisted = try corruptionContext.fetch(
                        FetchDescriptor<SteamStorageMountRecord>()
                    )
                    persisted.forEach { corruptionContext.delete($0) }
                    try corruptionContext.save()
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? SteamStorageMountMutationError,
                .persistenceVerificationFailed(root.standardizedFileURL.path)
            )
        }

        let verificationContext = ModelContext(container)
        let restored = try verificationContext.fetch(
            FetchDescriptor<SteamStorageMountRecord>()
        )
        let restoredByID = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restoredByID[firstID]?.path, root.standardizedFileURL.path)
        XCTAssertEqual(restoredByID[firstID]?.bookmark, Data("first-bookmark".utf8))
        XCTAssertEqual(restoredByID[firstID]?.createdAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(restoredByID[firstID]?.updatedAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(restoredByID[duplicateID]?.path, duplicatePath)
        XCTAssertEqual(restoredByID[duplicateID]?.bookmark, Data("duplicate-bookmark".utf8))
        XCTAssertEqual(restoredByID[duplicateID]?.createdAt, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(restoredByID[duplicateID]?.updatedAt, Date(timeIntervalSince1970: 40))
        XCTAssertTrue(appState.retainedSteamLibrarySecurityScopedPathsForTesting.isEmpty)
    }

    func testReconnectSteamStorageMountSaveFailureRollsBackAndPreservesExistingLease() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayReconnectRollback-\(UUID().uuidString)", directoryHint: .isDirectory)
        let oldRoot = root.appending(path: "Old", directoryHint: .isDirectory)
        let newRoot = root.appending(path: "New", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)

        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let oldBookmark = Data("old-bookmark".utf8)
        let mount = SteamStorageMountRecord(path: oldRoot.path, bookmark: oldBookmark)
        let game = SteamGameRecord(
            steamAppId: "33",
            name: "Rollback Game",
            installDir: "RollbackGame",
            libraryPath: oldRoot.appending(path: "SteamLibrary", directoryHint: .isDirectory).path,
            manifestPath: oldRoot.appending(path: "SteamLibrary/steamapps/appmanifest_33.acf").path,
            libraryBookmark: oldBookmark
        )
        context.insert(mount)
        context.insert(game)
        try context.save()

        let appState = AppState()
        _ = appState.restoreSteamStorageMountAccess(
            from: [mount],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { _ in
                SecurityScopedBookmarkResolvedURL(url: oldRoot, isStale: false)
            },
            securityScopeStarter: { _ in true }
        )
        XCTAssertEqual(
            appState.retainedSteamLibrarySecurityScopedPathsForTesting,
            [oldRoot.standardizedFileURL.path]
        )

        XCTAssertThrowsError(
            try appState.reconnectSteamStorageMount(
                mount,
                to: SteamStorageSelectionAuthorization(
                    root: newRoot,
                    bookmark: Data("new-bookmark".utf8)
                ),
                in: context,
                saveChanges: { _ in throw CocoaError(.fileWriteNoPermission) }
            )
        )

        XCTAssertEqual(mount.path, oldRoot.standardizedFileURL.path)
        XCTAssertEqual(mount.bookmark, oldBookmark)
        XCTAssertEqual(
            game.libraryPath,
            oldRoot.appending(path: "SteamLibrary", directoryHint: .isDirectory).path
        )
        XCTAssertEqual(game.libraryBookmark, oldBookmark)
        XCTAssertEqual(
            appState.retainedSteamLibrarySecurityScopedPathsForTesting,
            [oldRoot.standardizedFileURL.path]
        )
        appState.releaseAllSecurityScopedAccess()
    }

    func testReconnectSteamStorageMountVerificationFailureRestoresMountAndGameSnapshots() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayReconnectCompensation-\(UUID().uuidString)", directoryHint: .isDirectory)
        let oldRoot = root.appending(path: "Old", directoryHint: .isDirectory)
        let newRoot = root.appending(path: "New", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)

        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let oldBookmark = Data("reconnect-old-bookmark".utf8)
        let mount = SteamStorageMountRecord(
            id: "reconnect-compensation-mount",
            path: oldRoot.path,
            bookmark: oldBookmark,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let duplicateAtDestination = SteamStorageMountRecord(
            id: "reconnect-compensation-duplicate",
            path: newRoot.path,
            bookmark: Data("destination-bookmark".utf8),
            createdAt: Date(timeIntervalSince1970: 300),
            updatedAt: Date(timeIntervalSince1970: 400)
        )
        let oldLibrary = oldRoot.appending(path: "SteamLibrary", directoryHint: .isDirectory)
        let game = SteamGameRecord(
            steamAppId: "reconnect-compensation-game",
            name: "Compensation Game",
            installDir: "CompensationGame",
            libraryPath: oldLibrary.path,
            manifestPath: oldLibrary.appending(
                path: "steamapps/appmanifest_reconnect.acf",
                directoryHint: .notDirectory
            ).path,
            sizeOnDisk: 123,
            lastUpdated: Date(timeIntervalSince1970: 500),
            lastLaunchStatus: "old-status",
            graphicsBackendSelection: "automatic",
            libraryBookmark: oldBookmark
        )
        context.insert(mount)
        context.insert(duplicateAtDestination)
        context.insert(game)
        try context.save()
        let mountID = mount.id
        let duplicateID = duplicateAtDestination.id
        let gameID = game.steamAppId

        let appState = AppState()
        XCTAssertThrowsError(
            try appState.reconnectSteamStorageMount(
                mount,
                to: SteamStorageSelectionAuthorization(
                    root: newRoot,
                    bookmark: Data("reconnect-new-bookmark".utf8)
                ),
                in: context,
                saveChanges: { mutationContext in
                    try mutationContext.save()
                    let corruptionContext = ModelContext(container)
                    let persisted = try corruptionContext.fetch(
                        FetchDescriptor<SteamStorageMountRecord>()
                    )
                    persisted.forEach { corruptionContext.delete($0) }
                    try corruptionContext.save()
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? SteamStorageMountMutationError,
                .persistenceVerificationFailed(newRoot.standardizedFileURL.path)
            )
        }

        let verificationContext = ModelContext(container)
        let restoredMounts = try verificationContext.fetch(
            FetchDescriptor<SteamStorageMountRecord>()
        )
        let restoredMountsByID = Dictionary(
            uniqueKeysWithValues: restoredMounts.map { ($0.id, $0) }
        )
        XCTAssertEqual(restoredMounts.count, 2)
        XCTAssertEqual(restoredMountsByID[mountID]?.path, oldRoot.standardizedFileURL.path)
        XCTAssertEqual(restoredMountsByID[mountID]?.bookmark, oldBookmark)
        XCTAssertEqual(restoredMountsByID[mountID]?.createdAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(restoredMountsByID[mountID]?.updatedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(
            restoredMountsByID[duplicateID]?.path,
            newRoot.standardizedFileURL.path
        )
        XCTAssertEqual(
            restoredMountsByID[duplicateID]?.bookmark,
            Data("destination-bookmark".utf8)
        )

        let restoredGames = try verificationContext.fetch(
            FetchDescriptor<SteamGameRecord>()
        )
        let restoredGame = try XCTUnwrap(
            restoredGames.first { $0.steamAppId == gameID }
        )
        XCTAssertEqual(restoredGame.name, "Compensation Game")
        XCTAssertEqual(restoredGame.installDir, "CompensationGame")
        XCTAssertEqual(restoredGame.libraryPath, oldLibrary.standardizedFileURL.path)
        XCTAssertEqual(
            restoredGame.manifestPath,
            oldLibrary.appending(
                path: "steamapps/appmanifest_reconnect.acf",
                directoryHint: .notDirectory
            ).standardizedFileURL.path
        )
        XCTAssertEqual(restoredGame.sizeOnDisk, 123)
        XCTAssertEqual(restoredGame.lastUpdated, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(restoredGame.lastLaunchStatus, "old-status")
        XCTAssertEqual(restoredGame.graphicsBackendSelection, "automatic")
        XCTAssertEqual(restoredGame.libraryBookmark, oldBookmark)
        XCTAssertTrue(appState.retainedSteamLibrarySecurityScopedPathsForTesting.isEmpty)
    }

    func testStaleMovedMountRekeysRetainedAccessAfterPersistingResolvedPath() throws {
        let savedRoot = URL(fileURLWithPath: "/Volumes/Previous/SteamLibrary", isDirectory: true)
        let resolvedRoot = URL(fileURLWithPath: "/Volumes/Current/SteamLibrary", isDirectory: true)
        let bookmark = Data("stale-moved-bookmark".utf8)
        let refreshedBookmark = Data("refreshed-moved-bookmark".utf8)
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let record = SteamStorageMountRecord(path: savedRoot.path, bookmark: bookmark)
        context.insert(record)
        try context.save()

        let appState = AppState()
        let restoration = appState.restoreSteamStorageMountAccess(
            from: [record],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { _ in
                SecurityScopedBookmarkResolvedURL(url: resolvedRoot, isStale: true)
            },
            securityScopeStarter: { _ in true },
            bookmarkCreator: { url in
                XCTAssertEqual(url.standardizedFileURL.path, resolvedRoot.standardizedFileURL.path)
                return refreshedBookmark
            }
        )

        XCTAssertEqual(restoration.roots.map(\.path), [resolvedRoot.standardizedFileURL.path])
        XCTAssertEqual(record.path, resolvedRoot.standardizedFileURL.path)
        XCTAssertEqual(record.bookmark, refreshedBookmark)
        XCTAssertEqual(
            appState.retainedSteamLibrarySecurityScopedPathsForTesting,
            [resolvedRoot.standardizedFileURL.path]
        )

        appState.releaseSteamStorageSecurityScopedAccess(for: record.url)
        XCTAssertTrue(appState.retainedSteamLibrarySecurityScopedPathsForTesting.isEmpty)
    }

    func testMovedMountRefreshSaveFailureRestoresRecordAndKeepsOriginalLeaseKey() throws {
        let savedRoot = URL(fileURLWithPath: "/Volumes/Previous/SteamLibrary", isDirectory: true)
        let resolvedRoot = URL(fileURLWithPath: "/Volumes/Current/SteamLibrary", isDirectory: true)
        let bookmark = Data("moved-save-failure-bookmark".utf8)
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let record = SteamStorageMountRecord(path: savedRoot.path, bookmark: bookmark)
        let originalUpdatedAt = record.updatedAt
        context.insert(record)
        try context.save()

        let appState = AppState()
        let restoration = appState.restoreSteamStorageMountAccess(
            from: [record],
            in: context,
            allowsPathFallback: false,
            bookmarkResolver: { _ in
                SecurityScopedBookmarkResolvedURL(url: resolvedRoot, isStale: false)
            },
            securityScopeStarter: { _ in true },
            saveChanges: { _ in throw CocoaError(.fileWriteNoPermission) }
        )

        XCTAssertTrue(restoration.bookmarkPersistenceFailed)
        XCTAssertEqual(restoration.roots.map(\.path), [resolvedRoot.standardizedFileURL.path])
        XCTAssertEqual(record.path, savedRoot.standardizedFileURL.path)
        XCTAssertEqual(record.bookmark, bookmark)
        XCTAssertEqual(record.updatedAt, originalUpdatedAt)
        XCTAssertEqual(
            appState.retainedSteamLibrarySecurityScopedPathsForTesting,
            [savedRoot.standardizedFileURL.path]
        )
        let verificationContext = ModelContext(container)
        XCTAssertEqual(
            try verificationContext.fetch(FetchDescriptor<SteamStorageMountRecord>()).first?.path,
            savedRoot.standardizedFileURL.path
        )
        appState.releaseAllSecurityScopedAccess()
    }

    func testUnavailableExternalSteamLibraryIsOmittedInsteadOfBlockingLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayUnavailableSteamLibrary-\(UUID().uuidString)", directoryHint: .isDirectory)
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let record = SteamGameRecord(
            steamAppId: "20",
            name: "Unavailable Game",
            installDir: "UnavailableGame",
            libraryPath: root.path,
            manifestPath: root.appending(path: "steamapps/appmanifest_20.acf").path
        )
        context.insert(record)
        try context.save()

        let appState = AppState()
        let restored = appState.restoredSteamLibraryRoots(
            from: [record],
            in: context,
            allowsPathFallback: false
        )

        XCTAssertTrue(restored.isEmpty)
        XCTAssertEqual(appState.currentNotice?.kind, .warning)
    }

    func testAppStateSurfacesInvalidBookmarkAsReconnectNeeded() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let settings = AppSettingsRecord(
            selectedRootPath: "/tmp/ForgePlayPreviouslySelected",
            selectedRootBookmark: Data([0, 1, 2, 3]),
            languageMode: ForgePlayLanguageMode.english.rawValue,
            isLanguageModeOverrideEnabled: true,
            languageModeOverrideSource: AppLanguageModeOverrideSource.userSettings.rawValue
        )
        context.insert(settings)
        try context.save()

        let appState = AppState()
        try appState.load(from: context)

        XCTAssertNil(appState.selectedRootURL)
        XCTAssertEqual(appState.currentNotice?.kind, .warning)
        XCTAssertEqual(
            appState.currentNotice?.message,
            "Could not restore saved access to ForgePlay App Data Location. Select it again from the system picker."
        )
    }

    func testSavingDefaultManagedRootPersistsPathWithoutSecurityScopedBookmark() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let settings = AppSettingsRecord(
            languageMode: ForgePlayLanguageMode.english.rawValue,
            isLanguageModeOverrideEnabled: true,
            languageModeOverrideSource: AppLanguageModeOverrideSource.userSettings.rawValue
        )
        context.insert(settings)
        try context.save()

        let defaultManagedRoot = try PathManager.defaultManagedRootURL()
        let appState = AppState()
        appState.setLanguageModeFromUserSelection(.english)
        appState.setPersistedFileSelection(defaultManagedRoot, for: .selectedRoot)

        appState.save(to: context)

        XCTAssertNil(appState.currentNotice)

        let savedSettings = try XCTUnwrap(try context.fetch(FetchDescriptor<AppSettingsRecord>()).first)
        XCTAssertEqual(savedSettings.selectedRootPath, defaultManagedRoot.path)
        XCTAssertNil(savedSettings.selectedRootBookmark)
    }

    func testAppStateBookmarkFailureHandlerDoesNotReplaceCurrentNotice() {
        let missingRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMissingBookmark-\(UUID().uuidString)", directoryHint: .isDirectory)
        let appState = AppState()
        appState.setNotice("Keep this notice", kind: .success)

        var failures: [SecurityScopedBookmarkCreationFailure] = []
        let data = appState.bookmarkData(for: missingRoot, role: .selectedRoot) {
            failures.append($0)
        }

        XCTAssertNil(data)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.role, .selectedRoot)
        XCTAssertEqual(appState.currentNotice?.message, "Keep this notice")
        XCTAssertEqual(appState.currentNotice?.kind, .success)
    }

    func testSavingUserPreferenceDoesNotRewriteUnrelatedInstallerBookmark() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let installerPath = "/Volumes/Offline/SteamSetup.exe"
        let installerBookmark = Data("installer-bookmark".utf8)
        let settings = AppSettingsRecord(
            lastSteamInstallerPath: installerPath,
            lastSteamInstallerBookmark: installerBookmark
        )
        context.insert(settings)
        try context.save()

        let appState = AppState()
        let warning = appState.saveUserPreferencesAfterMutation(to: context) {
            appState.themeMode = .pumpkinSpice
        }

        XCTAssertNil(warning)
        XCTAssertEqual(settings.themeMode, ForgePlayThemeMode.pumpkinSpice.rawValue)
        XCTAssertNil(settings.gptkExecutablePath)
        XCTAssertNil(settings.gptkExecutableBookmark)
        XCTAssertEqual(settings.lastSteamInstallerPath, installerPath)
        XCTAssertEqual(settings.lastSteamInstallerBookmark, installerBookmark)
    }

    func testSavingSameUnavailableInstallerPreservesItsBookmarkAndClearsRetiredRuntimeColumns() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let installer = URL(fileURLWithPath: "/Volumes/Offline/SteamSetup.exe")
        let installerBookmark = Data("installer-bookmark".utf8)
        let settings = AppSettingsRecord(
            gptkExecutablePath: "/Volumes/Offline/LegacyRuntime/wine",
            gptkExecutableBookmark: Data("retired-runtime-bookmark".utf8),
            lastSteamInstallerPath: installer.path,
            lastSteamInstallerBookmark: installerBookmark
        )
        context.insert(settings)
        try context.save()

        let appState = AppState()
        appState.steamInstallerURL = installer
        appState.save(to: context)

        XCTAssertNil(settings.gptkExecutablePath)
        XCTAssertNil(settings.gptkExecutableBookmark)
        XCTAssertEqual(settings.lastSteamInstallerBookmark, installerBookmark)
    }

    func testPassiveManagedRootRestorationPreservesSamePathBookmark() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let root = URL(fileURLWithPath: "/Volumes/Offline/ForgePlayManagedData", isDirectory: true)
        let bookmark = Data("managed-root-bookmark".utf8)
        let settings = AppSettingsRecord(
            selectedRootPath: root.path,
            selectedRootBookmark: bookmark,
            managedStorageLayoutVersion: ForgePlayManagedStorageLayout.currentVersion
        )
        context.insert(settings)
        try context.save()

        let appState = AppState()
        appState.setPersistedFileSelection(
            root,
            for: .selectedRoot,
            requiresBookmarkReplacement: false
        )
        appState.save(to: context)

        XCTAssertEqual(settings.selectedRootPath, root.path)
        XCTAssertEqual(settings.selectedRootBookmark, bookmark)
    }

    func testExplicitSameInstallerReselectionDoesNotKeepPreviousBookmarkOnCreationFailure() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let installer = URL(fileURLWithPath: "/Volumes/Offline/SteamSetup.exe")
        let settings = AppSettingsRecord(
            lastSteamInstallerPath: installer.path,
            lastSteamInstallerBookmark: Data("previous-installer-bookmark".utf8)
        )
        context.insert(settings)
        try context.save()

        let appState = AppState()
        appState.setPersistedFileSelection(installer, for: .steamInstaller)

        XCTAssertNil(appState.save(to: context))
        XCTAssertNil(settings.gptkExecutablePath)
        XCTAssertNil(settings.gptkExecutableBookmark)
        XCTAssertEqual(settings.lastSteamInstallerPath, installer.path)
        XCTAssertNil(settings.lastSteamInstallerBookmark)
    }

    func testManagedDataSheetOffersSecurityScopedCustomRootRelocation() throws {
        let sheetHostSource = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/UI/SheetHostView.swift"),
            encoding: .utf8
        )
        let locationSource = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/UI/ManagedStorageLocationView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(sheetHostSource.contains("ManagedStorageLocationView()"))
        XCTAssertTrue(locationSource.contains("private func chooseManagedStorageDestination()"))
        XCTAssertTrue(locationSource.contains("appState.bookmarkData(for: destination, role: .selectedRoot)"))
        XCTAssertTrue(locationSource.contains("services.relocateManagedStorage("))
        XCTAssertTrue(locationSource.contains("destinationBookmark: bookmark"))
        XCTAssertTrue(locationSource.contains("private func restoreDefaultManagedStorage()"))
        XCTAssertTrue(locationSource.contains("private struct RelocationRequest"))
        XCTAssertTrue(locationSource.contains("복사 후 이전 관리 데이터 삭제"))
        XCTAssertTrue(locationSource.contains("ForgePlay가 관리하는 데이터가 삭제됩니다"))
        XCTAssertTrue(locationSource.contains("requestManagedStorageRelocation"))
        XCTAssertTrue(locationSource.contains("private func preparationFailureView"))
        XCTAssertTrue(locationSource.contains("macOS 폴더 선택기 열기"))
        XCTAssertFalse(locationSource.contains("case .authorizationRequired, .failed"))
    }

    func testMissingCustomManagedRootBookmarkRequiresFolderPickerIntervention() {
        let root = URL(fileURLWithPath: "/Volumes/ForgePlayExternalData", isDirectory: true)

        XCTAssertTrue(
            ManagedStorageActivationError.managedRootBookmarkRequired(root)
                .requiresUserIntervention
        )
    }

    func testDisconnectingSteamStorageMountReleasesCurrentSessionSecurityScopeLease() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/ForgePlay/App/AppState.swift"),
            encoding: .utf8
        )
        let suffix = try XCTUnwrap(
            source.components(separatedBy: "func disconnectSteamStorageMount").last
        )
        let body = try XCTUnwrap(
            suffix.components(separatedBy: "func connectSteamStorageMount").first
        )

        XCTAssertTrue(body.contains("try saveChanges(modelContext)"))
        XCTAssertTrue(body.contains("releaseSteamStorageSecurityScopedAccess(for: disconnectedRoot)"))
        XCTAssertLessThan(
            try XCTUnwrap(body.range(of: "try saveChanges(modelContext)")?.lowerBound),
            try XCTUnwrap(body.range(of: "releaseSteamStorageSecurityScopedAccess")?.lowerBound)
        )
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appending(path: "project.yml").path) {
                return url
            }
        }
        throw XCTSkip("Could not locate project root from #filePath")
    }
}

private actor SteamStorageConnectionOperationGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
