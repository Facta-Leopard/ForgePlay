import Foundation

struct AppUpdateManifest: Codable, Hashable, Sendable {
    struct Download: Codable, Hashable, Sendable {
        var assetName: String
        var url: URL
        var sha256: String
        var byteSize: Int
    }

    var schema: String
    var schemaVersion: Int
    var product: String
    var channel: String
    var marketingVersion: String
    var buildNumber: Int
    var releaseTag: String
    var publishedAt: String
    var minimumMacOSVersion: String
    var releaseURL: URL
    var download: Download

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case schemaVersion
        case product
        case channel
        case marketingVersion
        case buildNumber
        case releaseTag
        case publishedAt
        case minimumMacOSVersion
        case releaseURL
        case download
    }
}

struct AppUpdateNoUpdate: Hashable, Sendable {
    var manifest: AppUpdateManifest
    /// True when the valid remote stable manifest is older than this installed build.
    var manifestIsStale: Bool
}

enum AppUpdateCheckResult: Hashable, Sendable {
    case updateRequired(AppUpdateManifest)
    case noUpdate(AppUpdateNoUpdate)
    case failure(AppUpdateCheckError)
}

enum AppUpdateCheckError: LocalizedError, Hashable, Sendable {
    case invalidLocalVersion(String)
    case invalidLocalBuild(String)
    case invalidManifest(String)
    case invalidHTTPStatus(Int)
    case invalidResolvedURL
    case invalidMIMEType(String?)
    case responseTooLarge(received: Int, limit: Int)
    case transport(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidLocalVersion:
            "ForgePlay의 현재 버전 번호가 올바르지 않습니다."
        case .invalidLocalBuild:
            "ForgePlay의 현재 빌드 번호가 올바르지 않습니다."
        case .invalidManifest:
            "공개 릴리스 정보의 형식 또는 검증 정보가 올바르지 않습니다."
        case .invalidHTTPStatus(let status):
            "릴리스 정보 서버가 올바르지 않은 상태를 반환했습니다: HTTP \(status)"
        case .invalidResolvedURL:
            "릴리스 정보가 허용되지 않은 주소로 이동해 업데이트 확인을 중단했습니다."
        case .invalidMIMEType:
            "릴리스 정보 서버가 JSON 응답을 반환하지 않았습니다."
        case .responseTooLarge:
            "릴리스 정보 응답이 허용된 크기를 초과했습니다."
        case .transport:
            "릴리스 정보를 가져오지 못했습니다."
        case .cancelled:
            "업데이트 확인이 취소되었습니다."
        }
    }
}

enum AppUpdateManifestValidator {
    static let expectedSchema = "./current-release.schema.json"
    static let expectedProduct = "ForgePlay"
    static let expectedChannel = "stable"
    static let releaseHost = "github.com"
    static let releasePathPrefix = "/Facta-Leopard/ForgePlay/releases/"

    static func validate(_ manifest: AppUpdateManifest) throws {
        guard manifest.schema == expectedSchema,
              manifest.schemaVersion == 1,
              manifest.product == expectedProduct,
              manifest.channel == expectedChannel else {
            throw AppUpdateCheckError.invalidManifest("schema, product, or channel")
        }
        guard isNumericVersion(manifest.marketingVersion),
              manifest.buildNumber > 0,
              isUTCDateTime(manifest.publishedAt),
              isNumericVersion(manifest.minimumMacOSVersion),
              isReleaseTag(manifest.releaseTag),
              isAssetName(manifest.download.assetName),
              isLowercaseSHA256(manifest.download.sha256),
              manifest.download.byteSize > 0 else {
            throw AppUpdateCheckError.invalidManifest("field format")
        }

        let expectedTag = "v\(normalizedVersion(manifest.marketingVersion))"
        guard releaseTagBase(manifest.releaseTag) == expectedTag else {
            throw AppUpdateCheckError.invalidManifest("release tag does not match marketing version")
        }
        guard isTrustedGitHubURL(
            manifest.releaseURL,
            expectedPath: "\(releasePathPrefix)tag/\(manifest.releaseTag)"
        ), isTrustedGitHubURL(
            manifest.download.url,
            expectedPath: "\(releasePathPrefix)download/\(manifest.releaseTag)/\(manifest.download.assetName)"
        ) else {
            throw AppUpdateCheckError.invalidManifest("release URL")
        }
    }

    static func positiveBuildNumber(from value: String) throws -> Int {
        guard value.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
              let build = Int(value), build > 0 else {
            throw AppUpdateCheckError.invalidLocalBuild(value)
        }
        return build
    }

    static func localVersionComponents(from value: String) throws -> [Int] {
        guard let components = numericVersionComponents(value) else {
            throw AppUpdateCheckError.invalidLocalVersion(value)
        }
        return components
    }

    static func versionComponents(from value: String) throws -> [Int] {
        guard let components = numericVersionComponents(value) else {
            throw AppUpdateCheckError.invalidManifest("marketing version")
        }
        return components
    }

    private static func isNumericVersion(_ value: String) -> Bool {
        numericVersionComponents(value) != nil
    }

    private static func numericVersionComponents(_ value: String) -> [Int]? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count), components.allSatisfy({ component in
            !component.isEmpty && component.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 48 && scalar.value <= 57
            }
        }) else { return nil }
        let parsed = components.compactMap { Int($0) }
        guard parsed.count == components.count else { return nil }
        return parsed + Array(repeating: 0, count: 3 - parsed.count)
    }

    private static func normalizedVersion(_ value: String) -> String {
        let components = value.split(separator: ".").map(String.init)
        return (components + Array(repeating: "0", count: 3)).prefix(3).joined(separator: ".")
    }

    private static func isReleaseTag(_ value: String) -> Bool {
        guard value.hasPrefix("v") else { return false }
        let versionAndSuffix = value.dropFirst()
        let base = versionAndSuffix.split(
            maxSplits: 1,
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "-" || $0 == "+" }
        )
        guard let version = base.first, isNumericVersion(String(version)) else { return false }
        guard base.count == 1 else {
            guard let suffix = base.last, !suffix.isEmpty else { return false }
            return suffix.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 65 && scalar.value <= 90)
                    || (scalar.value >= 97 && scalar.value <= 122)
                    || scalar == "." || scalar == "-"
            }
        }
        return true
    }

    private static func releaseTagBase(_ value: String) -> String {
        String(value.split(
            maxSplits: 1,
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "-" || $0 == "+" }
        ).first ?? "")
    }

    private static func isUTCDateTime(_ value: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }

    private static func isAssetName(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              isASCIIAlphaNumeric(first), value.count <= 255 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            isASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "_" || scalar == "+" || scalar == "-"
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.unicodeScalars.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func isTrustedGitHubURL(_ url: URL, expectedPath: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == releaseHost
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
            && components.path == expectedPath
    }
}

final class AppUpdateService: @unchecked Sendable {
    static let manifestURL = URL(
        string: "https://facta-leopard.github.io/ForgePlay/site-data/current-release.json"
    )
    static let maximumManifestBytes = 64 * 1024

    private let session: URLSession
    private let manifestURL: URL?
    private let timeout: TimeInterval

    init(
        session: URLSession = AppUpdateService.defaultSession(),
        manifestURL: URL? = AppUpdateService.manifestURL,
        timeout: TimeInterval = 20
    ) {
        self.session = session
        self.manifestURL = manifestURL
        self.timeout = timeout
    }

    static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return configuration
    }

    /// Checks the installed application's release identity against the stable manifest.
    func checkForUpdate(bundle: Bundle = .main) async -> AppUpdateCheckResult {
        let localVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let localBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return await checkForUpdate(localVersion: localVersion, localBuild: localBuild)
    }

    /// Injection point for deterministic callers and tests that already hold the local release identity.
    func checkForUpdate(localVersion: String, localBuild: String) async -> AppUpdateCheckResult {
        do {
            let localVersionComponents = try AppUpdateManifestValidator.localVersionComponents(from: localVersion)
            let localBuildNumber = try AppUpdateManifestValidator.positiveBuildNumber(from: localBuild)
            guard let manifestURL else {
                return .failure(.invalidResolvedURL)
            }
            var request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            try Task.checkCancellation()
            guard response.url == manifestURL else {
                bytes.task.cancel()
                return .failure(.invalidResolvedURL)
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                bytes.task.cancel()
                return .failure(.transport("non-HTTP response"))
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                bytes.task.cancel()
                return .failure(.invalidHTTPStatus(httpResponse.statusCode))
            }
            guard isJSONMIMEType(httpResponse.value(forHTTPHeaderField: "Content-Type")) else {
                bytes.task.cancel()
                return .failure(.invalidMIMEType(httpResponse.value(forHTTPHeaderField: "Content-Type")))
            }
            if response.expectedContentLength > Int64(Self.maximumManifestBytes) {
                bytes.task.cancel()
                return .failure(.responseTooLarge(
                    received: Int(clamping: response.expectedContentLength),
                    limit: Self.maximumManifestBytes
                ))
            }
            let data = try await boundedManifestData(from: bytes)
            try Task.checkCancellation()

            let manifest = try JSONDecoder().decode(AppUpdateManifest.self, from: data)
            try AppUpdateManifestValidator.validate(manifest)
            let remoteVersionComponents = try AppUpdateManifestValidator.versionComponents(
                from: manifest.marketingVersion
            )
            let versionOrdering = compareVersions(
                remoteVersionComponents,
                localVersionComponents
            )
            if versionOrdering == .orderedDescending
                || (versionOrdering == .orderedSame && manifest.buildNumber > localBuildNumber) {
                return .updateRequired(manifest)
            }
            return .noUpdate(AppUpdateNoUpdate(
                manifest: manifest,
                manifestIsStale: versionOrdering == .orderedAscending
                    || (versionOrdering == .orderedSame && manifest.buildNumber < localBuildNumber)
            ))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as AppUpdateCheckError {
            return .failure(error)
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.cancelled)
        } catch is DecodingError {
            return .failure(.invalidManifest("JSON decoding"))
        } catch {
            return .failure(.transport(String(describing: error)))
        }
    }

    private static func defaultSession() -> URLSession {
        URLSession(configuration: defaultSessionConfiguration())
    }

    private func compareVersions(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right ? .orderedAscending : .orderedDescending
        }
        if lhs.count == rhs.count {
            return .orderedSame
        }
        return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
    }

    private func boundedManifestData(
        from bytes: URLSession.AsyncBytes
    ) async throws -> Data {
        var data = Data()
        if bytes.task.countOfBytesExpectedToReceive > 0 {
            data.reserveCapacity(min(
                Int(clamping: bytes.task.countOfBytesExpectedToReceive),
                Self.maximumManifestBytes
            ))
        }
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumManifestBytes else {
                    bytes.task.cancel()
                    throw AppUpdateCheckError.responseTooLarge(
                        received: Self.maximumManifestBytes + 1,
                        limit: Self.maximumManifestBytes
                    )
                }
                data.append(byte)
            }
            return data
        } catch {
            bytes.task.cancel()
            throw error
        }
    }

    private func isJSONMIMEType(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "application/json"
    }
}
