import XCTest
@testable import ForgePlay

final class SteamSessionStateTests: XCTestCase {
    func testMissingSteamInstallationIsUnavailable() {
        let prefix = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: prefix) }

        let inspection = SteamSessionStateInspector().inspect(prefix: prefix)

        XCTAssertEqual(inspection, .unavailable)
    }

    func testInstalledSteamWithoutAccountDataRequiresSignIn() throws {
        let prefix = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: prefix) }
        try makeSteamDirectory(in: prefix)

        let inspection = SteamSessionStateInspector().inspect(prefix: prefix)

        XCTAssertEqual(inspection.state, .noAccountData)
        XCTAssertEqual(inspection.accountCount, 0)
        XCTAssertEqual(inspection.userDataDirectoryCount, 0)
        XCTAssertFalse(inspection.hasLocalAccountData)
    }

    func testRememberedAccountAndUserDataAreReportedWithoutAccountIdentity() throws {
        let prefix = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let steam = try makeSteamDirectory(in: prefix)
        let config = steam.appending(path: "config", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try """
        "users"
        {
            "76561198000000001"
            {
                "AccountName" "private-account-name"
                "PersonaName" "private-persona-name"
                "RememberPassword" "1"
                "MostRecent" "1"
            }
        }
        """.write(
            to: config.appending(path: "loginusers.vdf"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: steam.appending(path: "userdata/12345678", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        let inspection = SteamSessionStateInspector().inspect(prefix: prefix)

        XCTAssertEqual(inspection.state, .rememberedSignInConfigured)
        XCTAssertEqual(inspection.accountCount, 1)
        XCTAssertEqual(inspection.userDataDirectoryCount, 1)
        XCTAssertTrue(inspection.hasLocalAccountData)
        XCTAssertNil(inspection.issue)
        XCTAssertFalse(String(describing: inspection).contains("private-account-name"))
        XCTAssertFalse(String(describing: inspection).contains("private-persona-name"))
    }

    func testMalformedLoginUsersIsInvalidInsteadOfSignedIn() throws {
        let prefix = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let steam = try makeSteamDirectory(in: prefix)
        let config = steam.appending(path: "config", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "\"users\" { \"76561198000000001\" {".write(
            to: config.appending(path: "loginusers.vdf"),
            atomically: true,
            encoding: .utf8
        )

        let inspection = SteamSessionStateInspector().inspect(prefix: prefix)

        XCTAssertEqual(inspection.state, .invalid)
        XCTAssertNotNil(inspection.issue)
        XCTAssertFalse(inspection.hasLocalAccountData)
    }

    func testSymlinkLoginUsersIsInvalidInsteadOfFollowed() throws {
        let prefix = temporaryRoot()
        let external = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalLoginUsers-\(UUID().uuidString).vdf")
        defer {
            try? FileManager.default.removeItem(at: prefix)
            try? FileManager.default.removeItem(at: external)
        }
        let steam = try makeSteamDirectory(in: prefix)
        let config = steam.appending(path: "config", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "\"users\" { }".write(to: external, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: config.appending(path: "loginusers.vdf"),
            withDestinationURL: external
        )

        let inspection = SteamSessionStateInspector().inspect(prefix: prefix)

        XCTAssertEqual(inspection.state, .invalid)
    }

    func testNumericUserDataSymlinkIsInvalidInsteadOfFollowed() throws {
        let prefix = temporaryRoot()
        let external = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalUserData-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: prefix)
            try? FileManager.default.removeItem(at: external)
        }
        let steam = try makeSteamDirectory(in: prefix)
        let userData = steam.appending(path: "userdata", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: userData.appending(path: "12345678"),
            withDestinationURL: external
        )

        let inspection = SteamSessionStateInspector().inspect(prefix: prefix)

        XCTAssertEqual(inspection.state, .invalid)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ForgePlaySteamSessionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @discardableResult
    private func makeSteamDirectory(in prefix: URL) throws -> URL {
        let steam = prefix.appending(
            path: "drive_c/Program Files (x86)/Steam",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: steam, withIntermediateDirectories: true)
        return steam
    }
}
