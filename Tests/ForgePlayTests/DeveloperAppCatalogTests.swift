import XCTest
@testable import ForgePlay

final class DeveloperAppCatalogTests: XCTestCase {
    func testInDevelopmentCatalogContainsRequestedProjectIdentityAndKind() {
        XCTAssertEqual(
            DeveloperAppCatalog.inDevelopmentListings.map(\.name),
            [
                "MajorDex",
                "ForgeKit",
                "HareWatch",
                "WarrenNet",
                "Hazel&Peanut",
                "GrayLine",
                "Leporis Ascendant"
            ]
        )
        XCTAssertEqual(
            DeveloperAppCatalog.inDevelopmentListings.map(\.summaryKey),
            [
                "선택한 프로젝트를 실행하지 않고 읽기 전용으로 분석해 구조와 실행 흐름을 시각적으로 살펴볼 수 있는 macOS 앱입니다.",
                "Apple 플랫폼 전용 게임 엔진으로, Apple Intelligence 기반 AI를 활용해 2D·3D 게임을 제작할 수 있습니다.",
                "유틸리티",
                "유틸리티",
                "게임",
                "게임",
                "게임"
            ]
        )
        XCTAssertEqual(
            DeveloperAppCatalog.inDevelopmentListings.map(\.platform),
            [.mac, .mac, .mac, .mac, .iPhone, .iPhone, .iPad]
        )
        XCTAssertEqual(
            DeveloperAppCatalog.inDevelopmentListings(for: .mac).map(\.name),
            ["MajorDex", "ForgeKit", "HareWatch", "WarrenNet"]
        )
        XCTAssertEqual(
            DeveloperAppCatalog.inDevelopmentListings(for: .iPhone).map(\.name),
            ["Hazel&Peanut", "GrayLine"]
        )
        XCTAssertEqual(
            DeveloperAppCatalog.inDevelopmentListings(for: .iPad).map(\.name),
            ["Leporis Ascendant"]
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
            "DeveloperAppWarrenNet": "WarrenNet.png",
            "DeveloperAppHazelAndPeanut": "HazelAndPeanut.png",
            "DeveloperAppGrayLine": "GrayLine.png",
            "DeveloperAppLeporisAscendant": "LeporisAscendant.png"
        ]
        let allProjects = DeveloperAppCatalog.inDevelopmentListings

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
        XCTAssertFalse(source.contains("DeveloperAppCatalog.upcomingListings"))
        XCTAssertFalse(source.contains("DeveloperUpcomingProjectCard"))
        XCTAssertFalse(source.contains("upcomingProjectsSection"))
        XCTAssertTrue(source.contains("DeveloperAppCatalog.inDevelopmentListings"))
        XCTAssertTrue(
            source.contains("DeveloperAppCatalog.inDevelopmentListings(for: selectedPlatform)")
        )
        XCTAssertTrue(source.contains("private var developmentControls"))
        XCTAssertTrue(source.contains("%d개의 프로젝트"))
        XCTAssertTrue(source.contains("if let artworkAssetName = listing.artworkAssetName"))
        XCTAssertTrue(source.contains("else if let homepageURL = listing.homepageURL"))
        XCTAssertTrue(source.contains("title: \"홈페이지 열기\""))

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
        XCTAssertTrue(tileSource.contains("if let summaryKey = listing.summaryKey"))
        XCTAssertTrue(tileSource.contains("Text(appState.localized(summaryKey))"))
        XCTAssertFalse(tileSource.contains("DeveloperAppBadge"))
    }

    func testMacCatalogContainsForgePlayAndProvidedAppStoreListings() {
        let listings = DeveloperAppCatalog.listings(for: .mac)

        XCTAssertEqual(
            Set(listings.compactMap(\.appStoreID)),
            Set([
                "6782226580",
                "6785348274",
                "6781878576",
                "6763971665",
                "6765845295"
            ])
        )
        XCTAssertEqual(listings.count, 6)
        XCTAssertEqual(listings.first?.name, "ForgePlay")
        XCTAssertTrue(listings.allSatisfy { $0.platform == .mac })
        XCTAssertTrue(listings.allSatisfy { $0.kind == .app })
    }

    func testForgePlayCatalogListingUsesBundledArtworkAndOfficialHomepage() throws {
        let listing = try XCTUnwrap(
            DeveloperAppCatalog.listings.first { $0.name == "ForgePlay" }
        )
        XCTAssertNil(listing.appStoreID)
        XCTAssertNil(listing.appStoreSlug)
        XCTAssertNil(listing.appStoreURL)
        XCTAssertNil(listing.artworkURL)
        XCTAssertEqual(
            listing.summaryKey,
            "세계최초, Apple Silicon Mac에서 Windows 게임을 맥 네이티브 게임모드로 실행하는 앱입니다."
        )
        XCTAssertEqual(listing.artworkAssetName, "DeveloperAppForgePlay")
        XCTAssertEqual(listing.homepageURL, ExternalLinkPolicy.forgePlayHomepageURL)

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let imageset = projectRoot.appending(
            path: "Resources/Assets.xcassets/DeveloperAppForgePlay.imageset"
        )
        let contents = try String(
            contentsOf: imageset.appending(path: "Contents.json"),
            encoding: .utf8
        )
        XCTAssertTrue(contents.contains(#""filename" : "ForgePlay.png""#))
        XCTAssertGreaterThan(
            try imageset.appending(path: "ForgePlay.png")
                .resourceValues(forKeys: [.fileSizeKey])
                .fileSize ?? 0,
            0
        )
    }

    func testIPadCatalogContainsProvidedAppleSiliconCompatibleListings() {
        let listings = DeveloperAppCatalog.listings(for: .iPad)

        XCTAssertEqual(
            Set(listings.compactMap(\.appStoreID)),
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
            Set(listings.compactMap(\.appStoreID)),
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
        for listing in DeveloperAppCatalog.listings where listing.appStoreID != nil {
            let appStoreID = try XCTUnwrap(listing.appStoreID)
            let appStoreURL = try XCTUnwrap(listing.appStoreURL)
            XCTAssertEqual(appStoreURL.scheme, "https")
            XCTAssertEqual(appStoreURL.host, "apps.apple.com")
            XCTAssertTrue(appStoreURL.path.hasSuffix("/id\(appStoreID)"))

            let artworkURL = try XCTUnwrap(listing.artworkURL)
            XCTAssertEqual(artworkURL.scheme, "https")
            XCTAssertTrue(artworkURL.host?.hasSuffix(".mzstatic.com") == true)
            XCTAssertNil(listing.artworkAssetName)
            XCTAssertNil(listing.homepageURL)
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
        XCTAssertEqual(try XCTUnwrap(byName["ForgePlay"]), allEight)
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
        let unreleasedListings = DeveloperAppCatalog.inDevelopmentListings
        for listing in unreleasedListings {
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
            "출시된 앱과 개발 중인 프로젝트를 살펴보세요.",
            "제작자의 다른 앱 보기",
            "개발 중",
            "제작자의 다른 앱 화면은 앱 카탈로그에서 출시된 앱을 소개하고, 별도의 개발 중 탭에서 기기별 진행 프로젝트를 보여줍니다.",
            "앱 카탈로그",
            "각 앱 카드에는 실제 지원 언어가 표시됩니다. App Store 앱은 App Store에서 보기를 누르면 공식 제품 페이지가 열립니다.",
            "개발 중 프로젝트",
            "%d개의 프로젝트",
            "이 디바이스에서 개발 중인 프로젝트가 아직 없습니다.",
            "다른 디바이스를 선택해 보세요.",
            "개발 중 탭에서도 Mac, iPad, iPhone을 선택해 해당 디바이스용 프로젝트만 볼 수 있습니다.",
            "Mac에는 MajorDex, ForgeKit, HareWatch, WarrenNet이, iPad에는 Leporis Ascendant가, iPhone에는 Hazel&Peanut과 GrayLine이 표시됩니다.",
            "개발 중 탭에서 HareWatch와 WarrenNet은 유틸리티로, Hazel&Peanut, GrayLine, Leporis Ascendant는 게임으로 표시됩니다.",
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
