import XCTest
@testable import ForgePlay

@MainActor
final class PathManagerTests: XCTestCase {
    func testConfigureRootCreatesExpectedFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = PathManager()
        try manager.configureRoot(root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: try manager.url(for: .steamSharedPrefix).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try manager.url(for: .launchLogs).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try manager.url(for: .runtimeInstallers).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try manager.url(for: .runtimeExtractedInstallers).path))
    }

    func testRestorePersistedRootDoesNotCreateMissingRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMissingPersistedRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = PathManager()

        XCTAssertThrowsError(try manager.restorePersistedRoot(root)) { error in
            guard case PathManagerError.missing(let url) = error else {
                return XCTFail("Expected missing, got \(error)")
            }
            XCTAssertEqual(url.path, root.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertNil(manager.rootURL)
    }

    func testRestorePersistedRootDoesNotCreateManagedFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRestoreReferenceRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let manager = PathManager()
        try manager.restorePersistedRoot(root)

        XCTAssertEqual(manager.rootURL?.standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: ForgePlayPathRole.logs.rawValue).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: ForgePlayPathRole.prefixes.rawValue).path))
    }

    func testWorkflowRootRestoreClearsRootWhenPreviousRootFailsValidation() throws {
        let stableRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayWorkflowStableRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        let brokenRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayWorkflowBrokenRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: stableRoot)
            try? FileManager.default.removeItem(at: brokenRoot)
        }

        let manager = PathManager()
        try manager.configureRoot(stableRoot)
        try Data("not a directory".utf8).write(to: brokenRoot)

        XCTAssertThrowsError(try manager.restoreWorkflowRoot(brokenRoot)) { error in
            guard case PathManagerError.unsafeDirectory(let url) = error else {
                return XCTFail("Expected unsafeDirectory, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, brokenRoot.standardizedFileURL.path)
        }
        XCTAssertNil(manager.rootURL)
    }

    func testWorkflowRootRestoreClearsRootWhenSnapshotHadNoRoot() throws {
        let stableRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayWorkflowNilRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: stableRoot) }

        let manager = PathManager()
        try manager.configureRoot(stableRoot)

        try manager.restoreWorkflowRoot(nil)

        XCTAssertNil(manager.rootURL)
    }

    func testConfigureRootKeepsPreviousRootWhenNewRootFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayStableRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        let invalidRoot = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayInvalidRoot-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: invalidRoot)
        }

        let manager = PathManager()
        try manager.configureRoot(root)
        try Data("not a directory".utf8).write(to: invalidRoot)

        XCTAssertThrowsError(try manager.configureRoot(invalidRoot))
        XCTAssertEqual(manager.rootURL?.path, root.path)
    }

    func testConfigureRootMapsReadOnlyVolumeCreateFailureToNotWritable() throws {
        let root = URL(fileURLWithPath: "/Volumes/ReadOnlyForgePlay/ForgePlayRoot", isDirectory: true)
        let fileManager = ReadOnlyCreateDirectoryFileManager()
        let manager = PathManager(fileManager: fileManager)

        XCTAssertThrowsError(try manager.configureRoot(root)) { error in
            guard case PathManagerError.notWritable(let url) = error else {
                return XCTFail("Expected notWritable, got \(error)")
            }
            XCTAssertEqual(url.path, root.path)
        }
        XCTAssertNil(manager.rootURL)
    }

    func testReadOnlyVolumeErrorRecognizesUnderlyingPOSIXEROFS() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EROFS)
                )
            ]
        )

        XCTAssertTrue(PathManager.isReadOnlyVolumeError(error))
    }

    func testConfigureRootRejectsSymlinkRootDirectory() throws {
        let target = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRootTarget-\(UUID().uuidString)", directoryHint: .isDirectory)
        let symlink = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayRootSymlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: symlink)
            try? FileManager.default.removeItem(at: target)
        }

        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let manager = PathManager()

        XCTAssertThrowsError(try manager.configureRoot(symlink)) { error in
            guard case PathManagerError.unsafeDirectory(let url) = error else {
                return XCTFail("Expected unsafeDirectory, got \(error)")
            }
            XCTAssertEqual(url.path, symlink.path)
        }
        XCTAssertNil(manager.rootURL)
    }

    func testConfigureRootRejectsSymlinkManagedRoleDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayManagedRoleRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalLogs = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalLogs-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalLogs)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalLogs, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: ForgePlayPathRole.logs.rawValue, directoryHint: .isDirectory),
            withDestinationURL: externalLogs
        )

        let manager = PathManager()

        XCTAssertThrowsError(try manager.configureRoot(root)) { error in
            guard case PathManagerError.unsafeDirectory(let url) = error else {
                return XCTFail("Expected unsafeDirectory, got \(error)")
            }
            XCTAssertEqual(url.path, root.appending(path: ForgePlayPathRole.logs.rawValue).path)
        }
        XCTAssertNil(manager.rootURL)
    }

    func testSanitizedFileNameRejectsTraversalLikeAndControlOnlyNames() {
        XCTAssertEqual(PathManager.sanitizedFileName(".."), "ForgePlay")
        XCTAssertEqual(PathManager.sanitizedFileName("."), "ForgePlay")
        XCTAssertEqual(PathManager.sanitizedFileName("\n\t"), "ForgePlay")
        XCTAssertEqual(PathManager.sanitizedFileName("Game/Name:\nBuild"), "Game_Name__Build")
        XCTAssertEqual(PathManager.sanitizedFileName("../Secret"), "Secret")
        XCTAssertEqual(PathManager.sanitizedFileName("..\\Secret"), "Secret")
        XCTAssertEqual(PathManager.sanitizedFileName(".hidden"), "hidden")
        XCTAssertFalse(PathManager.sanitizedFileName("Game..Name").contains(".."))
    }

    func testCreateLogURLSanitizesFileExtension() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayLogPathTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = PathManager()
        try manager.configureRoot(root)

        let url = try manager.createLogURL(kind: "launch", name: "..", extension: "../txt")

        XCTAssertTrue(url.path.hasPrefix(try manager.url(for: .launchLogs).path))
        XCTAssertTrue(url.lastPathComponent.contains("_ForgePlay_launch.txt"))
        XCTAssertFalse(url.lastPathComponent.contains(".."))
        XCTAssertFalse(url.lastPathComponent.contains("/"))
    }

    func testSkeletonPrefixIsNotMarkedUsableUntilWineInitializesDosdevices() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)

        XCTAssertFalse(prefixManager.isUsablePrefix(at: prefixURL))

        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let dosdevices = prefixURL.appending(path: "dosdevices", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dosdevices.appending(path: "c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win64\n".write(
            to: prefixURL.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(prefixManager.isUsablePrefix(at: prefixURL))
    }

    func testUsablePrefixRejectsArchitectureMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayPrefixTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathManager = PathManager()
        try pathManager.configureRoot(root)
        let prefixManager = PrefixManager(pathManager: pathManager, runner: SafeProcessRunner())
        let metadata = try prefixManager.createSteamSharedPrefix()
        let prefixURL = URL(fileURLWithPath: metadata.path)

        try FileManager.default.createDirectory(
            at: prefixURL.appending(path: "drive_c", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let dosdevices = prefixURL.appending(path: "dosdevices", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: dosdevices.appending(path: "c:", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "WINE REGISTRY Version 2\n#arch=win32\n".write(
            to: prefixURL.appending(path: "system.reg"),
            atomically: true,
            encoding: .utf8
        )
        try "WINE REGISTRY Version 2\n".write(
            to: prefixURL.appending(path: "user.reg"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(try prefixManager.prefixArchitecture(at: prefixURL), "win32")
        XCTAssertFalse(prefixManager.isUsablePrefix(at: prefixURL))
        XCTAssertFalse(prefixManager.isUsablePrefix(at: prefixURL, expectedArchitecture: "win64"))
    }
}

private final class ReadOnlyCreateDirectoryFileManager: FileManager {
    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        isDirectory?.pointee = false
        return false
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError)
    }
}
