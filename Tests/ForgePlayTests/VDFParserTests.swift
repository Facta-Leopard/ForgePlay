import XCTest
@testable import ForgePlay

final class VDFParserTests: XCTestCase {
    func testParsesNestedLibraryFolders() throws {
        let text = """
        "libraryfolders"
        {
            "0"
            {
                "path" "/Users/test/SteamLibrary"
                "label" ""
            }
        }
        """

        let parsed = try VDFParser().parse(text)
        let root = try XCTUnwrap(parsed["libraryfolders"]?.objectValue)
        let first = try XCTUnwrap(root["0"]?.objectValue)

        XCTAssertEqual(first["path"]?.stringValue, "/Users/test/SteamLibrary")
    }

    func testIgnoresLineComments() throws {
        let text = """
        // comment
        "AppState"
        {
            "appid" "1245620"
            "name" "ELDEN RING"
        }
        """

        let parsed = try VDFParser().parse(text)
        let appState = try XCTUnwrap(parsed["AppState"]?.objectValue)

        XCTAssertEqual(appState["appid"]?.stringValue, "1245620")
        XCTAssertEqual(appState["name"]?.stringValue, "ELDEN RING")
    }

    func testRejectsUnterminatedQuotedString() {
        let text = #"""
        "AppState"
        {
            "appid" "1245620"
            "name" "Broken Manifest
        }
        """#

        XCTAssertThrowsError(try VDFParser().parse(text)) { error in
            XCTAssertEqual(error as? VDFParserError, .unexpectedEnd)
        }
    }

    func testRejectsDanglingEscapeInQuotedString() {
        let text = #"""
        "AppState"
        {
            "appid" "1245620"
            "name" "Broken Manifest\
        }
        """#

        XCTAssertThrowsError(try VDFParser().parse(text)) { error in
            XCTAssertEqual(error as? VDFParserError, .unexpectedEnd)
        }
    }

    func testSerializerRoundTripsSteamLibraryWindowsPathsAndEscapes() throws {
        let document: [String: VDFValue] = [
            "libraryfolders": .object([
                "1": .object([
                    "path": .string("D:\\Steam \"Library\""),
                    "label": .string("external\nvolume"),
                    "apps": .object([:])
                ]),
                "0": .object([
                    "path": .string("C:\\Program Files (x86)\\Steam")
                ])
            ])
        ]

        let serialized = VDFSerializer().serialize(document)
        let parsed = try VDFParser().parse(serialized)
        let zeroRange = try XCTUnwrap(serialized.range(of: "\"0\""))
        let oneRange = try XCTUnwrap(serialized.range(of: "\"1\""))

        XCTAssertEqual(parsed, document)
        XCTAssertLessThan(zeroRange.lowerBound, oneRange.lowerBound)
    }
}
