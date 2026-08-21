import XCTest
@testable import ForgePlay

final class FileSystemItemPolicyTests: XCTestCase {
    func testFileSystemPolicyErrorPreservesPathInTechnicalSummary() {
        let file = URL(fileURLWithPath: "/tmp/ForgePlay/unsafe-renderer.dll")
        let error = FileSystemItemPolicyError.notRegularNonSymlinkFile(file)

        let summary = forgePlayTechnicalErrorSummary(error)

        XCTAssertTrue(summary.contains(file.path), summary)
        XCTAssertFalse(summary.contains("FileSystemItemPolicyError 0"), summary)
    }

    func testThrowingFilePolicyAcceptsOnlyRegularNonSymlinkNonHardlinkedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayFilePolicyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalFile = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalFile-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalFile)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let regularFile = root.appending(path: "regular.txt")
        let linkedFile = root.appending(path: "linked.txt")
        let hardlinkedFile = root.appending(path: "hardlinked.txt")
        try "regular".write(to: regularFile, atomically: true, encoding: .utf8)
        try "external".write(to: externalFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: externalFile)
        try FileManager.default.linkItem(at: externalFile, to: hardlinkedFile)

        XCTAssertNoThrow(try FileSystemItemPolicy.requireRegularNonSymlinkFile(regularFile))
        XCTAssertTrue(FileSystemItemPolicy.isRegularNonSymlinkFile(regularFile))
        XCTAssertFalse(FileSystemItemPolicy.isRegularNonSymlinkFile(linkedFile))
        XCTAssertThrowsError(try FileSystemItemPolicy.requireRegularNonSymlinkFile(linkedFile)) { error in
            guard case FileSystemItemPolicyError.notRegularNonSymlinkFile(let url) = error else {
                return XCTFail("Expected notRegularNonSymlinkFile, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, linkedFile.standardizedFileURL.path)
        }
        XCTAssertFalse(FileSystemItemPolicy.isRegularNonSymlinkFile(hardlinkedFile))
        XCTAssertThrowsError(try FileSystemItemPolicy.requireRegularNonSymlinkFile(hardlinkedFile)) { error in
            guard case FileSystemItemPolicyError.notRegularNonSymlinkFile(let url) = error else {
                return XCTFail("Expected notRegularNonSymlinkFile, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, hardlinkedFile.standardizedFileURL.path)
        }
    }

    func testThrowingDirectoryPolicyRejectsSymlinkDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayDirectoryPolicyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalDirectory = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalDirectory-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalDirectory)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        let regularDirectory = root.appending(path: "Regular", directoryHint: .isDirectory)
        let linkedDirectory = root.appending(path: "Linked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: regularDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: externalDirectory)

        XCTAssertNoThrow(try FileSystemItemPolicy.requireNonSymlinkDirectory(regularDirectory))
        XCTAssertTrue(FileSystemItemPolicy.isNonSymlinkDirectory(regularDirectory))
        XCTAssertFalse(FileSystemItemPolicy.isNonSymlinkDirectory(linkedDirectory))
        XCTAssertThrowsError(try FileSystemItemPolicy.requireNonSymlinkDirectory(linkedDirectory)) { error in
            guard case FileSystemItemPolicyError.notNonSymlinkDirectory(let url) = error else {
                return XCTFail("Expected notNonSymlinkDirectory, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, linkedDirectory.standardizedFileURL.path)
        }
    }
}
