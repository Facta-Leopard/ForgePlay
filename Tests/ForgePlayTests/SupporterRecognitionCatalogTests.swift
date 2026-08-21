import XCTest
@testable import ForgePlay

final class SupporterRecognitionCatalogTests: XCTestCase {
    func testPublishedSupporterCatalogIsUniqueTrimmedAndContainsNoPlaceholderCopy() {
        let names = SupporterRecognitionCatalog.names
        let forbiddenPlaceholderFragments = [
            "Anonymous",
            "익명",
            "후원자 명단",
            "향후 업데이트",
        ]

        XCTAssertEqual(
            Set(names).count,
            names.count,
            "Every engraved supporter name must be unique."
        )

        for name in names {
            XCTAssertEqual(
                name,
                name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            XCTAssertFalse(name.isEmpty)
            XCTAssertFalse(name.contains("\n"))
            for fragment in forbiddenPlaceholderFragments {
                XCTAssertFalse(
                    name.localizedCaseInsensitiveContains(fragment),
                    "Published supporter catalog contains placeholder copy: \(fragment)"
                )
            }
        }
    }

    func testHallTitleIsLocalizedForEverySupportedLanguage() {
        let key = "후원자 명예의 전당"

        for language in ForgePlayLanguageMode.allCases where language != .system {
            let localized = ForgePlayLocalization.localized(key, language: language)
            XCTAssertFalse(
                localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Empty \(language.rawValue) Hall of Supporters localization."
            )
            if language != .korean {
                XCTAssertNil(
                    localized.range(of: "[가-힣]", options: .regularExpression),
                    "Korean fallback remains in \(language.rawValue) Hall of Supporters localization."
                )
            }
        }
    }

    func testHallLocalizationResourcesDoNotRetainRosterExplanations() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let forbiddenKeys = [
            "후원자 명단",
            "공개 표기 수: %d",
            "아직 공개된 후원자 명단이 없습니다.",
            "익명 표기",
            "공개를 원하는 이름이나 닉네임",
        ]

        for language in ForgePlayLanguageMode.allCases {
            guard let localeIdentifier = language.localeIdentifier else { continue }
            let resource = root.appending(
                path: "Resources/\(localeIdentifier).lproj/Localizable.strings"
            )
            let contents = try String(contentsOf: resource, encoding: .utf8)

            for key in forbiddenKeys {
                XCTAssertFalse(
                    contents.contains("\"\(key)\" ="),
                    "\(localeIdentifier) unexpectedly retains Hall explanatory copy: \(key)"
                )
            }
        }
    }
}
