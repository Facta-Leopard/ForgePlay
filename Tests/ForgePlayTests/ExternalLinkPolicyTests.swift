import XCTest
@testable import ForgePlay

final class ExternalLinkPolicyTests: XCTestCase {
    func testProductExternalLinksResolveToExpectedURLs() {
        XCTAssertEqual(
            ExternalLinkPolicy.steamOfficialDownloadURL?.absoluteString,
            "https://store.steampowered.com/about/"
        )
        XCTAssertEqual(
            ExternalLinkPolicy.appleGamePortingToolkitDownloadURL?.absoluteString,
            "https://developer.apple.com/games/game-porting-toolkit/"
        )
        XCTAssertEqual(
            ExternalLinkPolicy.forgePlayHomepageURL?.absoluteString,
            "https://facta-leopard.github.io/ForgePlay/"
        )
        XCTAssertEqual(
            ExternalLinkPolicy.forgePlayAnnouncementsURL?.absoluteString,
            "https://facta-leopard.github.io/ForgePlay/updates.html"
        )
        XCTAssertEqual(
            ExternalLinkPolicy.forgePlayWhyURL?.absoluteString,
            "https://facta-leopard.github.io/ForgePlay/why.html"
        )
        XCTAssertEqual(
            ExternalLinkPolicy.forgePlayRepositoryStarURL?.absoluteString,
            "https://github.com/Facta-Leopard/ForgePlay"
        )
        XCTAssertEqual(
            ExternalLinkPolicy.forgePlayRepositoryURL?.absoluteString,
            "https://github.com/Facta-Leopard/ForgePlay/tree/main"
        )
        XCTAssertEqual(
            ExternalLinkPolicy.forgePlaySponsorsURL?.absoluteString,
            "https://github.com/sponsors/Facta-Leopard"
        )
        XCTAssertEqual(
            ExternalLinkPolicy.forgePlayReleasesURL?.absoluteString,
            "https://github.com/Facta-Leopard/ForgePlay/releases"
        )
        XCTAssertEqual(
            ExternalLinkPolicy.macOSSoftwareUpdateSettingsURL?.scheme,
            "x-apple.systempreferences"
        )
    }

    func testWhyStoryURLUsesTheSelectedAppLanguage() {
        XCTAssertEqual(
            ExternalLinkPolicy.forgePlayWhyStoryURL(language: .korean)?
                .absoluteString,
            "https://facta-leopard.github.io/ForgePlay/why.html?lang=ko#full-story"
        )
        XCTAssertEqual(
            ExternalLinkPolicy.forgePlayWhyStoryURL(language: .traditionalChinese)?
                .absoluteString,
            "https://facta-leopard.github.io/ForgePlay/why.html?lang=zh-Hant#full-story"
        )
    }

    func testHTTPSURLBuilderRejectsMissingHost() {
        XCTAssertNil(ExternalLinkPolicy.httpsURL(host: " ", path: "/about/"))
    }

    @MainActor
    func testExternalLinkPolicyReportsMissingLinksAndFinderItems() {
        XCTAssertFalse(ExternalLinkPolicy.open(nil))

        let missingItem = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayMissingFinderItem-\(UUID().uuidString)")
        XCTAssertFalse(ExternalLinkPolicy.revealInFinder(missingItem))
    }

    func testProductionSourcesDoNotForceUnwrapStringURLs() throws {
        let sourcesRoot = try projectRoot()
            .appending(path: "Sources/ForgePlay", directoryHint: .isDirectory)
        let regex = try NSRegularExpression(pattern: #"URL\s*\(\s*string\s*:[^\n]*\)\s*!"#)
        let swiftFiles = try sourceFiles(under: sourcesRoot)
        var violations: [String] = []

        for file in swiftFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
            if regex.firstMatch(in: contents, range: range) != nil {
                violations.append(file.path)
            }
        }

        XCTAssertTrue(violations.isEmpty, "Forced URL(string:) unwraps remain in production sources: \(violations)")
    }

    func testProductionSourcesDoNotUseRuntimeTrapShortcuts() throws {
        let sourcesRoot = try projectRoot()
            .appending(path: "Sources/ForgePlay", directoryHint: .isDirectory)
        let forbiddenPatterns = [
            #"\btry!"#,
            #"\bas\s*!"#,
            #"fatalError\s*\("#,
            #"preconditionFailure\s*\("#,
            #"assertionFailure\s*\("#,
            #"URL\s*\(\s*string\s*:[^\n]*\)\s*!"#
        ]
        let regexes = try forbiddenPatterns.map { try NSRegularExpression(pattern: $0) }
        let swiftFiles = try sourceFiles(under: sourcesRoot)
        var violations: [String] = []

        for file in swiftFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
            if regexes.contains(where: { $0.firstMatch(in: contents, range: range) != nil }) {
                violations.append(file.path)
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Production sources must not use runtime trap shortcuts or forced URL unwraps: \(violations)"
        )
    }

    func testProductionUIUsesCentralWorkspaceOpenPolicy() throws {
        let uiRoot = try projectRoot()
            .appending(path: "Sources/ForgePlay/UI", directoryHint: .isDirectory)
        let regex = try NSRegularExpression(pattern: #"NSWorkspace\.shared\.(open|activateFileViewerSelecting)"#)
        let swiftFiles = try sourceFiles(under: uiRoot)
        var violations: [String] = []

        for file in swiftFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
            if regex.firstMatch(in: contents, range: range) != nil {
                violations.append(file.path)
            }
        }

        XCTAssertTrue(violations.isEmpty, "UI sources must route open/reveal failures through shared policy: \(violations)")
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

    private func sourceFiles(under root: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return try (enumerator?.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else {
                return nil
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true ? url : nil
        } ?? [])
    }
}
