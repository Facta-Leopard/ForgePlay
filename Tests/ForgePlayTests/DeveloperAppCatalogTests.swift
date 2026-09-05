import XCTest
@testable import ForgePlay

final class DeveloperAppCatalogTests: XCTestCase {
    func testUpcomingCatalogContainsMajorDexAndForgeKit() {
        XCTAssertEqual(
            DeveloperAppCatalog.upcomingListings.map(\.name),
            ["MajorDex", "ForgeKit"]
        )
        XCTAssertTrue(
            DeveloperAppCatalog.upcomingListings.allSatisfy {
                $0.summaryKey?.isEmpty == false
            }
        )
    }

    func testInDevelopmentCatalogContainsOnlyRequestedProjectIdentity() {
        XCTAssertEqual(
            DeveloperAppCatalog.inDevelopmentListings.map(\.name),
            ["HareWatch", "WarrenNet"]
        )
        XCTAssertTrue(
            DeveloperAppCatalog.inDevelopmentListings.allSatisfy {
                $0.summaryKey == nil
            }
        )
    }

    func testUnreleasedProjectsUseBundledArtworkAssets() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expectedFilenames = [
            "DeveloperAppMajorDex": "MajorDex.png",
            "DeveloperAppForgeKit": "ForgeKit.png",
            "DeveloperAppHareWatch": "HareWatch.png",
            "DeveloperAppWarrenNet": "WarrenNet.png"
        ]
        let allProjects = DeveloperAppCatalog.upcomingListings +
            DeveloperAppCatalog.inDevelopmentListings

        XCTAssertEqual(
            Set(allProjects.map(\.artworkAssetName)),
            Set(expectedFilenames.keys)
        )

        for listing in allProjects {
            let imageset = projectRoot.appending(
                path: "Resources/Assets.xcassets/\(listing.artworkAssetName).imageset"
            )
            let contentsURL = imageset.appending(path: "Contents.json")
            let contents = try String(contentsOf: contentsURL, encoding: .utf8)
            let filename = try XCTUnwrap(expectedFilenames[listing.artworkAssetName])
            XCTAssertTrue(contents.contains(#""filename" : "\#(filename)""#))

            let artworkURL = imageset.appending(path: filename)
            let resourceValues = try artworkURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            XCTAssertEqual(resourceValues.isRegularFile, true)
            XCTAssertGreaterThan(resourceValues.fileSize ?? 0, 0)
        }
    }

    func testDeveloperAppsViewSeparatesCatalogAndInDevelopmentPresentation() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/ForgePlay/UI/DeveloperAppsView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private enum DeveloperAppsTab"))
        XCTAssertTrue(source.contains("case appCatalog"))
        XCTAssertTrue(source.contains("case inDevelopment"))
        XCTAssertTrue(source.contains("DeveloperAppCatalog.upcomingListings"))
        XCTAssertTrue(source.contains("DeveloperUpcomingProjectCard(listing: listing)"))
        XCTAssertTrue(source.contains("DeveloperAppCatalog.inDevelopmentListings"))

        let tileStart = try XCTUnwrap(
            source.range(of: "private struct DeveloperInDevelopmentProjectTile")
        )
        let tileEnd = try XCTUnwrap(
            source.range(
                of: "private struct DeveloperAppCard",
                range: tileStart.upperBound..<source.endIndex
            )
        )
        let tileSource = source[tileStart.lowerBound..<tileEnd.lowerBound]
        XCTAssertTrue(tileSource.contains("artworkAssetName: listing.artworkAssetName"))
        XCTAssertTrue(tileSource.contains("Text(listing.name)"))
        XCTAssertFalse(tileSource.contains("summaryKey"))
        XCTAssertFalse(tileSource.contains("DeveloperAppBadge"))
    }

    func testMacCatalogContainsProvidedAppStoreListings() {
        let listings = DeveloperAppCatalog.listings(for: .mac)

        XCTAssertEqual(
            Set(listings.map(\.appStoreID)),
            Set([
                "6782226580",
                "6785348274",
                "6781878576",
                "6763971665",
                "6765845295"
            ])
        )
        XCTAssertEqual(listings.count, 5)
        XCTAssertTrue(listings.allSatisfy { $0.platform == .mac })
        XCTAssertTrue(listings.allSatisfy { $0.kind == .app })
    }

    func testIPadCatalogContainsProvidedAppleSiliconCompatibleListings() {
        let listings = DeveloperAppCatalog.listings(for: .iPad)

        XCTAssertEqual(
            Set(listings.map(\.appStoreID)),
            Set([
                "6763970447",
                "6761378169",
                "6764760496"
            ])
        )
        XCTAssertEqual(listings.count, 3)
        XCTAssertTrue(listings.allSatisfy { $0.platform == .iPad })
        XCTAssertTrue(
            listings.allSatisfy {
                $0.compatibilities == [.appleSiliconMac]
            }
        )
    }

    func testIPhoneCatalogContainsProvidedGameListings() {
        let listings = DeveloperAppCatalog.listings(for: .iPhone)

        XCTAssertEqual(
            Set(listings.map(\.appStoreID)),
            Set([
                "6770305364",
                "6767978392"
            ])
        )
        XCTAssertEqual(listings.count, 2)
        XCTAssertTrue(listings.allSatisfy { $0.platform == .iPhone })
        XCTAssertTrue(listings.allSatisfy { $0.kind == .game })
    }

    func testCatalogUsesSecureOfficialAppStoreAndArtworkURLs() throws {
        for listing in DeveloperAppCatalog.listings {
            let appStoreURL = try XCTUnwrap(listing.appStoreURL)
            XCTAssertEqual(appStoreURL.scheme, "https")
            XCTAssertEqual(appStoreURL.host, "apps.apple.com")
            XCTAssertTrue(appStoreURL.path.hasSuffix("/id\(listing.appStoreID)"))

            let artworkURL = try XCTUnwrap(listing.artworkURL)
            XCTAssertEqual(artworkURL.scheme, "https")
            XCTAssertTrue(artworkURL.host?.hasSuffix(".mzstatic.com") == true)
        }
    }

    func testAppStoreURLBuilderRejectsUntrustedPathComponents() {
        XCTAssertNil(
            ExternalLinkPolicy.appStoreProductURL(
                slug: "../unexpected",
                appID: "6782226580"
            )
        )
        XCTAssertNil(
            ExternalLinkPolicy.appStoreProductURL(
                slug: "hopdisk",
                appID: "6782226580?redirect=example.com"
            )
        )
        XCTAssertNil(
            ExternalLinkPolicy.appStoreProductURL(
                slug: "hopdisk",
                appID: "6782226580",
                storefront: "us/../kr"
            )
        )
    }

    func testCatalogRecordsActualSupportedLanguageCoverage() throws {
        let byName = Dictionary(
            uniqueKeysWithValues: DeveloperAppCatalog.listings.map { ($0.name, Set($0.supportedLanguages)) }
        )
        let allEight: Set<DeveloperAppLanguage> = [
            .english,
            .korean,
            .spanish,
            .german,
            .japanese,
            .simplifiedChinese,
            .traditionalChinese,
            .french
        ]
        let sixWithoutChinese = allEight.subtracting([.simplifiedChinese, .traditionalChinese])

        XCTAssertEqual(try XCTUnwrap(byName["HopDisk"]), allEight)
        XCTAssertEqual(try XCTUnwrap(byName["BunMixer"]), allEight)
        XCTAssertEqual(try XCTUnwrap(byName["LatchCast"]), allEight)
        XCTAssertEqual(try XCTUnwrap(byName["LoRAbit"]), sixWithoutChinese)
        XCTAssertEqual(try XCTUnwrap(byName["KaninDex"]), sixWithoutChinese)

        XCTAssertEqual(try XCTUnwrap(byName["Bunniki"]), sixWithoutChinese)
        XCTAssertEqual(try XCTUnwrap(byName["OpenBookLM"]), sixWithoutChinese)
        XCTAssertEqual(try XCTUnwrap(byName["BRAMBLETREAD"]), allEight)
        XCTAssertEqual(try XCTUnwrap(byName["Moonwhisk Vale"]), allEight)
        XCTAssertEqual(
            try XCTUnwrap(byName["Seolapin"]),
            Set([
                .english,
                .korean,
                .japanese,
                .simplifiedChinese,
                .traditionalChinese,
                .vietnamese,
                .thai,
                .spanish,
                .french,
                .german
            ])
        )
    }

    func testEveryCatalogSummaryIsLocalizedForForgePlayLanguages() throws {
        for listing in DeveloperAppCatalog.listings {
            for language in ForgePlayLanguageMode.allCases where language != .system {
                let localized = ForgePlayLocalization.localized(
                    listing.summaryKey,
                    language: language
                )
                XCTAssertFalse(
                    localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Empty \(language.rawValue) summary for \(listing.name)"
                )
                if language != .korean {
                    XCTAssertNil(
                        localized.range(of: "[가-힣]", options: .regularExpression),
                        "Korean fallback remains in \(language.rawValue) summary for \(listing.name)"
                    )
                }
            }
        }
    }

    func testEveryUnreleasedProjectSummaryIsLocalizedForForgePlayLanguages() throws {
        for listing in DeveloperAppCatalog.upcomingListings {
            let summaryKey = try XCTUnwrap(listing.summaryKey)
            for language in ForgePlayLanguageMode.allCases where language != .system {
                let localized = ForgePlayLocalization.localized(
                    summaryKey,
                    language: language
                )
                XCTAssertFalse(localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if language != .korean {
                    XCTAssertNil(
                        localized.range(of: "[가-힣]", options: .regularExpression),
                        "Korean fallback remains in \(language.rawValue) summary for \(listing.name)"
                    )
                }
            }
        }
    }

    func testDeveloperProjectTabsAndCompatibilityTitleHaveEightLocaleParity() {
        let keys = [
            "게임 호환성 DB",
            "출시된 앱과 곧 출시될 프로젝트, 개발 중인 프로젝트를 살펴보세요.",
            "제작자의 다른 앱 보기",
            "개발 중",
            "출시 예정",
            "조만간 출시 예정",
            "제작자의 다른 앱 화면은 출시된 앱과 출시 예정 프로젝트를 앱 카탈로그에서 소개하고, 별도의 개발 중 탭에서 진행 중인 프로젝트를 보여줍니다.",
            "앱 카탈로그와 출시 예정",
            "앱 카탈로그 탭 상단에는 MajorDex와 ForgeKit이 출시 예정 프로젝트로 표시됩니다.",
            "각 출시된 앱 카드에는 실제 지원 언어가 표시됩니다. App Store에서 보기를 누르면 공식 제품 페이지가 열립니다.",
            "개발 중 프로젝트",
            "개발 중 탭에는 HareWatch와 WarrenNet의 아이콘과 프로젝트 이름만 표시됩니다.",
            "개발 중 표시는 출시 일정이나 배포 준비 완료를 의미하지 않습니다."
        ]

        for language in ForgePlayLanguageMode.allCases where language != .system {
            for key in keys {
                let localized = ForgePlayLocalization.localized(key, language: language)
                XCTAssertFalse(
                    localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Empty \(language.rawValue) localization for \(key)"
                )
                if language != .korean {
                    XCTAssertNil(
                        localized.range(of: "[가-힣]", options: .regularExpression),
                        "Korean fallback remains in \(language.rawValue) localization for \(key)"
                    )
                }
            }
        }
    }

    func testEverySupportedLanguageNameAndCompatibilityNoteIsLocalized() {
        let languageKeys = Set(
            DeveloperAppCatalog.listings
                .flatMap(\.supportedLanguages)
                .map(\.titleKey)
        )
        let compatibilityKeys = Set(
            DeveloperAppCatalog.listings
                .flatMap(\.compatibilities)
                .flatMap { [$0.titleKey, $0.detailKey] }
        )
        let kindKeys = Set(
            DeveloperAppCatalog.listings
                .filter { $0.kind == .game }
                .map(\.kind.titleKey)
        )

        for language in ForgePlayLanguageMode.allCases where language != .system {
            for key in languageKeys
                .union(compatibilityKeys)
                .union(kindKeys) {
                let localized = ForgePlayLocalization.localized(key, language: language)
                XCTAssertFalse(
                    localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Empty \(language.rawValue) catalog metadata localization for \(key)"
                )
                if language != .korean {
                    XCTAssertNil(
                        localized.range(of: "[가-힣]", options: .regularExpression),
                        "Korean fallback remains in \(language.rawValue) catalog metadata for \(key)"
                    )
                }
            }
        }
    }
}
