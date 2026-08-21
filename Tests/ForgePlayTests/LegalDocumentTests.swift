import Foundation
import XCTest
@testable import ForgePlay

final class LegalDocumentTests: XCTestCase {
    func testBundledLegalDocumentCatalogMatchesProductFiles() throws {
        let root = try projectRoot()

        XCTAssertEqual(
            Set(LegalDocument.allCases.map(\.fileName)),
            [
                "ForgePlayLicenseNotice.md",
                "ForgePlayPrivacy.md",
                "ForgePlaySupport.md",
                "ForgePlayThirdPartyNotices.md",
                "NotoSans-OFL.txt",
                "NotoSansCJK-OFL.txt",
                "OFL.txt"
            ]
        )

        for document in LegalDocument.allCases where document != .licenseNotice {
            let relativePath = try XCTUnwrap(document.sourceRelativePath)
            let url = root.appending(path: relativePath, directoryHint: .notDirectory)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            XCTAssertEqual(values.isRegularFile, true, "\(document.fileName) must be a regular source file")
            XCTAssertNotEqual(values.isSymbolicLink, true, "\(document.fileName) must not be a symlink")
            XCTAssertGreaterThan(try String(contentsOf: url, encoding: .utf8).count, 400)
        }

        for localization in ["en", "ko", "es", "de", "ja", "zh-Hans", "zh-Hant", "fr"] {
            let url = root.appending(
                path: "Resources/\(localization).lproj/\(LegalDocument.licenseNotice.fileName)",
                directoryHint: .notDirectory
            )
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            XCTAssertEqual(values.isRegularFile, true, "\(localization) license notice must be a regular file")
            XCTAssertNotEqual(values.isSymbolicLink, true, "\(localization) license notice must not be a symlink")

            let contents = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(contents.contains("GPL-3.0-only"))
            XCTAssertTrue(contents.contains("Copyright (C) 2026 Facta-Leopard"))
            XCTAssertTrue(contents.contains("https://github.com/Facta-Leopard/ForgePlay"))
            XCTAssertTrue(contents.contains("LICENSES/GPL-3.0-only.txt"))
            XCTAssertGreaterThan(contents.count, 700)
        }
    }

    func testBundledFontLicensesAreDirectlyOpenableFromTheLegalCatalog() throws {
        for document in [
            LegalDocument.notoSansOFL,
            .notoSansCJKOFL,
            .nanumGothicOFL
        ] {
            let url = try XCTUnwrap(
                document.bundledURL(language: .english),
                "\(document.fileName) must be directly resolvable from the app bundle"
            )
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            XCTAssertEqual(values.isRegularFile, true)
            XCTAssertNotEqual(values.isSymbolicLink, true)
            let contents = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(contents.contains("SIL OPEN FONT LICENSE Version 1.1"))
            XCTAssertGreaterThan(contents.count, 4_000)
        }
    }

    func testLegalDocumentProductNoticesCoverCommercialBoundaries() throws {
        let root = try projectRoot()
        let legalRoot = root.appending(path: "Resources/Legal", directoryHint: .isDirectory)
        let privacy = try String(
            contentsOf: legalRoot.appending(path: LegalDocument.privacy.fileName),
            encoding: .utf8
        )
        let support = try String(
            contentsOf: legalRoot.appending(path: LegalDocument.support.fileName),
            encoding: .utf8
        )
        let notices = try String(
            contentsOf: legalRoot.appending(path: LegalDocument.thirdPartyNotices.fileName),
            encoding: .utf8
        )

        XCTAssertTrue(privacy.contains("does not send AI diagnostic logs to an external AI endpoint"))
        XCTAssertTrue(privacy.contains("does not ask for, store, or transmit Steam account passwords"))
        XCTAssertTrue(support.contains("Do not send Steam passwords"))
        XCTAssertTrue(support.contains("does not host runtime installers on an app server"))
        XCTAssertTrue(notices.contains("current Developer ID DMG configuration includes an Apple GPTK/D3DMetal evaluation renderer payload"))
        XCTAssertTrue(notices.contains("does not make a licensing determination"))
        XCTAssertTrue(notices.contains("does not claim ownership of Apple GPTK or D3DMetal"))
        XCTAssertTrue(notices.contains("does not redistribute these installers"))
        XCTAssertTrue(notices.contains("16680f8688ffcd467d2eb2146a9ce0343404581d"))
        XCTAssertTrue(notices.contains("76f45ef4a6bcff344c837c95a7dcc26e017e38b5846d5ae0cdcb5b86be2e2d31"))
        XCTAssertTrue(notices.contains("21f9d3a7f1ca82ca1dc9a288e30138b4f1feb6e71fc89b5a9181fed174b6bbe2"))

        let nanumIdentityURL = root.appending(
            path: "Resources/Runners/ForgePlayRuntime/Legal/NanumGothic/SOURCE-IDENTITY.json"
        )
        let identity = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: nanumIdentityURL))
                as? [String: Any]
        )
        XCTAssertEqual(identity["schema"] as? String, "ForgePlayNanumGothicSourceIdentityV1")
        XCTAssertEqual(identity["schemaVersion"] as? Int, 1)
        XCTAssertEqual(identity["sourceBytesModified"] as? Bool, false)
        let upstream = try XCTUnwrap(identity["upstream"] as? [String: Any])
        XCTAssertEqual(
            upstream["commit"] as? String,
            "16680f8688ffcd467d2eb2146a9ce0343404581d"
        )
        let files = try XCTUnwrap(identity["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(
            Set(files.compactMap { $0["sha256"] as? String }),
            [
                "76f45ef4a6bcff344c837c95a7dcc26e017e38b5846d5ae0cdcb5b86be2e2d31",
                "21f9d3a7f1ca82ca1dc9a288e30138b4f1feb6e71fc89b5a9181fed174b6bbe2",
                "eeacf16032901d0ed0456876ec77b8f0fda6b3fecec7d972f8543eb602e6c30f"
            ]
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
        throw XCTSkip("Project root not found")
    }
}
