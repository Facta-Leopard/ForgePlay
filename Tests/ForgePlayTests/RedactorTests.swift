import XCTest
@testable import ForgePlay

final class RedactorTests: XCTestCase {
    func testRedactsWineMappedDriveDirectoriesButPreservesDiagnosticBasenames() {
        let text = #"G:\Private User\SteamLibrary\steamapps\common\Secret Game\game.exe loaded D:\custom\renderer\dxgi.dll; C:\Program Files\Steam\steam.exe"#

        let output = Redactor().redact(text)

        XCTAssertTrue(output.contains(#"G:\[REDACTED_PATH]\game.exe"#), output)
        XCTAssertTrue(output.contains(#"D:\[REDACTED_PATH]\dxgi.dll"#), output)
        XCTAssertTrue(output.contains(#"C:\Program Files\Steam\steam.exe"#), output)
        XCTAssertFalse(output.contains("Private User"), output)
        XCTAssertFalse(output.contains("Secret Game"), output)
    }

    func testRedactsSecretsAndHomePath() {
        let redactor = Redactor()
        let text = """
        Authorization: Bearer sk-test-secret
        path=/Users/\(NSUserName())/Library/Application Support/ForgePlay
        steam=76561190000000000
        """

        let output = redactor.redact(text)

        XCTAssertFalse(output.contains("sk-test-secret"))
        XCTAssertFalse(output.contains("/Users/\(NSUserName())"))
        XCTAssertFalse(output.contains("76561190000000000"))
        XCTAssertTrue(output.contains("[REDACTED_SECRET]"))
    }

    func testRedactsStandaloneProviderTokensAndURLSecrets() {
        let redactor = Redactor()
        let text = """
        rawOpenAI=sk-proj-abcdefghijklmnopqrstuvwxyz1234567890
        github=ghp_abcdefghijklmnopqrstuvwxyz1234567890
        callback=https://user:password@example.com/callback?api_key=url-secret&ok=true
        cookie=set-cookie: sessionid=server-secret; Path=/
        """

        let output = redactor.redact(text)

        XCTAssertFalse(output.contains("sk-proj-abcdefghijklmnopqrstuvwxyz1234567890"))
        XCTAssertFalse(output.contains("ghp_abcdefghijklmnopqrstuvwxyz1234567890"))
        XCTAssertFalse(output.contains("user:password"))
        XCTAssertFalse(output.contains("url-secret"))
        XCTAssertFalse(output.contains("server-secret"))
        XCTAssertTrue(output.contains("[REDACTED_SECRET]"))
        XCTAssertTrue(output.contains("api_key=[REDACTED_SECRET]"))
    }

    func testRedactsOAuthAndSessionCredentialKeyVariants() {
        let redactor = Redactor()
        let text = #"""
        client_secret=plain-client-secret
        refresh_token: plain-refresh-token
        access-token='plain-access-token'
        session_id=plain-session-id
        callback=https://example.com/callback?client_secret=url-client-secret&session_id=url-session-id
        "client_secret": "json client secret with spaces"
        "refresh_token" "vdf-refresh-secret"
        "auth_token": "json-auth-token"
        "session_id" "vdf-session-secret"
        """#

        let output = redactor.redact(text)

        XCTAssertFalse(output.contains("plain-client-secret"))
        XCTAssertFalse(output.contains("plain-refresh-token"))
        XCTAssertFalse(output.contains("plain-access-token"))
        XCTAssertFalse(output.contains("plain-session-id"))
        XCTAssertFalse(output.contains("url-client-secret"))
        XCTAssertFalse(output.contains("url-session-id"))
        XCTAssertFalse(output.contains("json client secret with spaces"))
        XCTAssertFalse(output.contains("json-auth-token"))
        XCTAssertFalse(output.contains("vdf-refresh-secret"))
        XCTAssertFalse(output.contains("vdf-session-secret"))
        XCTAssertTrue(output.contains("[REDACTED_SECRET]"))
    }

    func testRedactsSteamAccountIdentifiersInVDFAndKeyValueLogs() {
        let redactor = Redactor()
        let text = #"""
        "AccountName" "privateSteamLogin"
        "PersonaName" "Private Persona"
        "AutoLoginUser" "rememberedUser"
        "SteamLoginSecure" "cookie-secret"
        account_name=plainLogin
        personaName: visiblePersona
        """#

        let output = redactor.redact(text)

        XCTAssertFalse(output.contains("privateSteamLogin"))
        XCTAssertFalse(output.contains("Private Persona"))
        XCTAssertFalse(output.contains("rememberedUser"))
        XCTAssertFalse(output.contains("cookie-secret"))
        XCTAssertFalse(output.contains("plainLogin"))
        XCTAssertFalse(output.contains("visiblePersona"))
        XCTAssertTrue(output.contains("[REDACTED_STEAM_ACCOUNT]"))
        XCTAssertTrue(output.contains("[REDACTED_SECRET]"))
    }

    func testRedactsAdditionalSensitivePathsLongestFirst() {
        let root = "/Volumes/Game Drive/ForgePlayRoot"
        let runner = "\(root)/Runners/Apple GPTK/gameportingtoolkit"
        let redactor = Redactor(additionalSensitivePaths: [root, runner])
        let text = """
        root=\(root)
        runner=\(runner)
        nested=\(root)/Logs/launch.log
        """

        let output = redactor.redact(text)

        XCTAssertFalse(output.contains(root))
        XCTAssertFalse(output.contains(runner))
        XCTAssertTrue(output.contains("[REDACTED_PATH]"))
        XCTAssertTrue(output.contains("[REDACTED_PATH]/Logs/launch.log"))
    }

    func testRedactedJSONDataPreservesValidJSONWhileRedactingSteamGuardAndEscapedWindowsUserPath() throws {
        let userName = NSUserName()
        let windowsPath = #"C:\Users\"# + userName + #"\AppData\Local\Steam\config.vdf"#
        let source: [String: Any] = [
            "message": "SteamGuard verification code 123456 must not survive",
            "windowsPath": windowsPath,
            "nested": [
                "token": "token=json-secret",
                "count": 7
            ]
        ]
        let encoded = try JSONSerialization.data(
            withJSONObject: source,
            options: [.prettyPrinted, .sortedKeys]
        )

        let redacted = try Redactor().redactedJSONData(encoded)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: redacted) as? [String: Any]
        )
        let nested = try XCTUnwrap(object["nested"] as? [String: Any])
        let redactedText = try XCTUnwrap(String(data: redacted, encoding: .utf8))

        XCTAssertEqual(object["message"] as? String, "[REDACTED_STEAM_GUARD_LINE]")
        XCTAssertEqual(
            object["windowsPath"] as? String,
            #"C:\Users\[REDACTED_PATH]"#
        )
        XCTAssertEqual(nested["token"] as? String, "[REDACTED_SECRET]")
        XCTAssertEqual(nested["count"] as? Int, 7)
        XCTAssertFalse(redactedText.contains("123456"), redactedText)
        XCTAssertNotEqual(object["windowsPath"] as? String, windowsPath)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: redacted))
    }

    func testRedactedJSONDataRedactsNumericSteamIdentifiersByKeyAndValue() throws {
        let source: [String: Any] = [
            "steamId": NSNumber(value: 76_561_198_000_000_000 as Int64),
            "nested": [
                "identifiers": [
                    NSNumber(value: 76_561_199_999_999_999 as Int64),
                    NSNumber(value: 42)
                ]
            ]
        ]
        let encoded = try JSONSerialization.data(withJSONObject: source)

        let redacted = try Redactor().redactedJSONData(encoded)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: redacted) as? [String: Any]
        )
        let nested = try XCTUnwrap(object["nested"] as? [String: Any])
        let identifiers = try XCTUnwrap(nested["identifiers"] as? [Any])
        let text = try XCTUnwrap(String(data: redacted, encoding: .utf8))

        XCTAssertEqual(object["steamId"] as? String, "[REDACTED_STEAM_ID]")
        XCTAssertEqual(identifiers.first as? String, "[REDACTED_STEAM_ID]")
        XCTAssertEqual(identifiers.last as? Int, 42)
        XCTAssertFalse(text.contains("7656119"), text)
    }
}
