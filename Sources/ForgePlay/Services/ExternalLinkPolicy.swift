import AppKit
import Foundation

enum ExternalLinkPolicy {
    static let steamOfficialDownloadURL = httpsURL(
        host: "store.steampowered.com",
        path: "/about/"
    )
    static let appleGamePortingToolkitDownloadURL = httpsURL(
        host: "developer.apple.com",
        path: "/games/game-porting-toolkit/"
    )
    static let forgePlayHomepageURL = httpsURL(
        host: "facta-leopard.github.io",
        path: "/ForgePlay/"
    )
    static let forgePlayAnnouncementsURL = httpsURL(
        host: "facta-leopard.github.io",
        path: "/ForgePlay/updates.html"
    )
    static let forgePlayWhyURL = httpsURL(
        host: "facta-leopard.github.io",
        path: "/ForgePlay/why.html"
    )
    static let forgePlayRepositoryStarURL = httpsURL(
        host: "github.com",
        path: "/Facta-Leopard/ForgePlay"
    )
    static let forgePlayRepositoryURL = httpsURL(
        host: "github.com",
        path: "/Facta-Leopard/ForgePlay/tree/main"
    )
    static let forgePlaySponsorsURL = httpsURL(
        host: "github.com",
        path: "/sponsors/Facta-Leopard"
    )
    static let forgePlayReleasesURL = httpsURL(
        host: "github.com",
        path: "/Facta-Leopard/ForgePlay/releases"
    )
    static let compatibilityWebsiteURL = httpsURL(
        host: "facta-leopard.github.io",
        path: "/ForgePlay/compatibility.html"
    )
    static let compatibilityReportURL = httpsURL(
        host: "github.com",
        path: "/facta-leopard/ForgePlay/issues/new"
    ).flatMap { baseURL in
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "template", value: "compatibility-report.yml")]
        return components?.url
    }
    static let macOSSoftwareUpdateSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
    )

    static func forgePlayWhyStoryURL(
        language: ForgePlayLanguageMode
    ) -> URL? {
        let resolvedLanguage = language == .system
            ? ForgePlaySystemLanguageResolver.resolvedLanguageMode()
            : language
        guard let languageIdentifier = resolvedLanguage.localeIdentifier,
              let baseURL = forgePlayWhyURL,
              var components = URLComponents(
                url: baseURL,
                resolvingAgainstBaseURL: false
              ) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "lang", value: languageIdentifier)
        ]
        components.fragment = "full-story"
        return components.url
    }

    static func appStoreProductURL(
        slug: String,
        appID: String,
        storefront: String = "us"
    ) -> URL? {
        let normalizedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStorefront = storefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slugCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let appIDCharacters = CharacterSet(charactersIn: "0123456789")
        let storefrontCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")

        guard !normalizedSlug.isEmpty,
              !normalizedAppID.isEmpty,
              !normalizedStorefront.isEmpty,
              normalizedSlug.unicodeScalars.allSatisfy(slugCharacters.contains),
              normalizedAppID.unicodeScalars.allSatisfy(appIDCharacters.contains),
              normalizedStorefront.unicodeScalars.allSatisfy(storefrontCharacters.contains) else {
            return nil
        }

        return httpsURL(
            host: "apps.apple.com",
            path: "/\(normalizedStorefront)/app/\(normalizedSlug)/id\(normalizedAppID)"
        )
    }

    static func httpsURL(host: String, path: String) -> URL? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = trimmedHost
        components.path = path.hasPrefix("/") ? path : "/\(path)"

        guard let url = components.url,
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    @MainActor
    @discardableResult
    static func open(_ url: URL?) -> Bool {
        guard let url else { return false }
        return NSWorkspace.shared.open(url)
    }

    @MainActor
    @discardableResult
    static func revealInFinder(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }
}
