import Foundation
import XCTest
@testable import ForgePlay

final class AppUpdateServiceTests: XCTestCase {
    func testDefaultSessionDisablesCacheCookiesAndCredentials() {
        let configuration = AppUpdateService.defaultSessionConfiguration()

        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 20)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 30)
    }

    func testSameBuildReportsNoUpdate() async throws {
        let manifest = try fixtureManifest(buildNumber: 2)
        let service = AppUpdateService(session: AppUpdateURLProtocol.session { request in
            try self.assertUpdateRequest(request)
            return try self.jsonResponse(for: request, manifest: manifest)
        })

        let result = await service.checkForUpdate(localVersion: "1.1", localBuild: "2")

        guard case .noUpdate(let noUpdate) = result else {
            return XCTFail("Expected no update, got \(result)")
        }
        XCTAssertEqual(noUpdate.manifest.buildNumber, 2)
        XCTAssertFalse(noUpdate.manifestIsStale)
    }

    func testHigherRemoteBuildReportsUpdateRequired() async throws {
        let manifest = try fixtureManifest(buildNumber: 3)
        let service = AppUpdateService(session: AppUpdateURLProtocol.session { request in
            try self.jsonResponse(for: request, manifest: manifest)
        })

        let result = await service.checkForUpdate(localVersion: "1.1", localBuild: "2")

        guard case .updateRequired(let remote) = result else {
            return XCTFail("Expected update-required, got \(result)")
        }
        XCTAssertEqual(remote.buildNumber, 3)
        XCTAssertEqual(remote.releaseURL.absoluteString, "https://github.com/Facta-Leopard/ForgePlay/releases/tag/v1.1.0")
    }

    func testLowerRemoteBuildReportsNoUpdateAndManifestStale() async throws {
        let manifest = try fixtureManifest(buildNumber: 1)
        let service = AppUpdateService(session: AppUpdateURLProtocol.session { request in
            try self.jsonResponse(for: request, manifest: manifest)
        })

        let result = await service.checkForUpdate(localVersion: "1.1", localBuild: "2")

        guard case .noUpdate(let noUpdate) = result else {
            return XCTFail("Expected no update, got \(result)")
        }
        XCTAssertTrue(noUpdate.manifestIsStale)
    }

    func testRejectsInvalidManifestBeforeVersionComparison() async throws {
        var manifest = try fixtureManifest(buildNumber: 3)
        manifest.download.url = URL(string: "https://example.com/ForgePlay-1.1-3.dmg")!
        let service = AppUpdateService(session: AppUpdateURLProtocol.session { request in
            try self.jsonResponse(for: request, manifest: manifest)
        })

        let result = await service.checkForUpdate(localVersion: "1.1", localBuild: "2")

        guard case .failure(.invalidManifest) = result else {
            return XCTFail("Expected invalid-manifest failure, got \(result)")
        }
    }

    func testRejectsNonJSONResponse() async throws {
        let manifest = try fixtureManifest(buildNumber: 3)
        let service = AppUpdateService(session: AppUpdateURLProtocol.session { request in
            let data = try JSONEncoder().encode(manifest)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            ))
            return (response, data)
        })

        let result = await service.checkForUpdate(localVersion: "1.1", localBuild: "2")

        XCTAssertEqual(result, .failure(.invalidMIMEType("text/html")))
    }

    func testRejectsResponseResolvedToAnotherURL() async throws {
        let manifest = try fixtureManifest(buildNumber: 3)
        let service = AppUpdateService(session: AppUpdateURLProtocol.session { _ in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(URL(string: "https://example.com/current-release.json")),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, try JSONEncoder().encode(manifest))
        })

        let result = await service.checkForUpdate(localVersion: "1.1", localBuild: "2")

        XCTAssertEqual(result, .failure(.invalidResolvedURL))
    }

    func testRejectsOversizedResponse() async throws {
        let service = AppUpdateService(session: AppUpdateURLProtocol.session { request in
            let data = Data(repeating: 0, count: AppUpdateService.maximumManifestBytes + 1)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json; charset=utf-8"]
            ))
            return (response, data)
        })

        let result = await service.checkForUpdate(localVersion: "1.1", localBuild: "2")

        XCTAssertEqual(result, .failure(.responseTooLarge(
            received: AppUpdateService.maximumManifestBytes + 1,
            limit: AppUpdateService.maximumManifestBytes
        )))
    }

    func testRejectsDeclaredOversizedResponseBeforeBodyBuffering() async throws {
        let declaredSize = AppUpdateService.maximumManifestBytes + 10_000
        let service = AppUpdateService(session: AppUpdateURLProtocol.session { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                    "Content-Length": String(declaredSize)
                ]
            ))
            return (response, Data("{}".utf8))
        })

        let result = await service.checkForUpdate(localVersion: "1.1", localBuild: "2")

        XCTAssertEqual(result, .failure(.responseTooLarge(
            received: declaredSize,
            limit: AppUpdateService.maximumManifestBytes
        )))
    }

    func testDeclaredOversizedStreamingResponseCancelsBeforeRemainingBodyIsDelivered() async throws {
        let declaredSize = AppUpdateService.maximumManifestBytes * 8
        let probe = AppUpdateStreamingProbe()
        let service = AppUpdateService(session: AppUpdateStreamingURLProtocol.session(
            declaredSize: declaredSize,
            probe: probe
        ))

        let result = await service.checkForUpdate(localVersion: "1.1", localBuild: "2")

        XCTAssertEqual(result, .failure(.responseTooLarge(
            received: declaredSize,
            limit: AppUpdateService.maximumManifestBytes
        )))
        for _ in 0..<100 where !probe.snapshot().wasStopped {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let snapshot = probe.snapshot()
        XCTAssertTrue(snapshot.wasStopped)
        XCTAssertLessThan(snapshot.deliveredBytes, declaredSize)
    }

    func testRejectsMalformedJSONAsInvalidManifest() async throws {
        let service = AppUpdateService(session: AppUpdateURLProtocol.session { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data("{not-json}".utf8))
        })

        let result = await service.checkForUpdate(localVersion: "1.1", localBuild: "2")

        guard case .failure(.invalidManifest) = result else {
            return XCTFail("Expected invalid-manifest failure, got \(result)")
        }
    }

    func testRejectsInvalidLocalBuildBeforeRequest() async {
        let service = AppUpdateService(session: AppUpdateURLProtocol.session { _ in
            XCTFail("Invalid local build must not make a request")
            throw URLError(.badURL)
        })

        let result = await service.checkForUpdate(localVersion: "1.1", localBuild: "1.1")

        XCTAssertEqual(result, .failure(.invalidLocalBuild("1.1")))
    }

    func testRejectsInvalidLocalVersionBeforeRequest() async {
        let service = AppUpdateService(session: AppUpdateURLProtocol.session { _ in
            XCTFail("Invalid local version must not make a request")
            throw URLError(.badURL)
        })

        let result = await service.checkForUpdate(localVersion: "1", localBuild: "2")

        XCTAssertEqual(result, .failure(.invalidLocalVersion("1")))
    }

    func testRejectsMissingConfiguredManifestURLBeforeRequest() async {
        let service = AppUpdateService(
            session: AppUpdateURLProtocol.session { _ in
                XCTFail("A missing manifest URL must not make a request")
                throw URLError(.badURL)
            },
            manifestURL: nil
        )

        let result = await service.checkForUpdate(localVersion: "1.1", localBuild: "2")

        XCTAssertEqual(result, .failure(.invalidResolvedURL))
    }

    func testHigherRemoteVersionRequiresUpdateEvenWhenRemoteBuildIsLower() async throws {
        let manifest = try fixtureManifest(marketingVersion: "1.10", buildNumber: 1)
        let service = AppUpdateService(session: AppUpdateURLProtocol.session { request in
            try self.jsonResponse(for: request, manifest: manifest)
        })

        let result = await service.checkForUpdate(localVersion: "1.9", localBuild: "2")

        guard case .updateRequired(let remote) = result else {
            return XCTFail("Expected update-required, got \(result)")
        }
        XCTAssertEqual(remote.marketingVersion, "1.10")
        XCTAssertEqual(remote.buildNumber, 1)
    }

    func testLowerRemoteVersionIsStaleEvenWhenRemoteBuildIsHigher() async throws {
        let manifest = try fixtureManifest(marketingVersion: "1.0", buildNumber: 99)
        let service = AppUpdateService(session: AppUpdateURLProtocol.session { request in
            try self.jsonResponse(for: request, manifest: manifest)
        })

        let result = await service.checkForUpdate(localVersion: "1.1", localBuild: "2")

        guard case .noUpdate(let noUpdate) = result else {
            return XCTFail("Expected no update, got \(result)")
        }
        XCTAssertTrue(noUpdate.manifestIsStale)
    }

    func testEquivalentTwoAndThreeComponentVersionsCompareBuilds() async throws {
        let manifest = try fixtureManifest(marketingVersion: "1.1.0", buildNumber: 3)
        let service = AppUpdateService(session: AppUpdateURLProtocol.session { request in
            try self.jsonResponse(for: request, manifest: manifest)
        })

        let result = await service.checkForUpdate(localVersion: "1.1", localBuild: "2")

        guard case .updateRequired(let remote) = result else {
            return XCTFail("Expected update-required, got \(result)")
        }
        XCTAssertEqual(remote.buildNumber, 3)
    }

    func testValidatorRejectsUnsupportedSchemaAndMismatchedTag() throws {
        var manifest = try fixtureManifest(buildNumber: 3)
        manifest.schemaVersion = 2
        XCTAssertThrowsError(try AppUpdateManifestValidator.validate(manifest))

        manifest = try fixtureManifest(buildNumber: 3)
        manifest.releaseTag = "v1.2.0"
        XCTAssertThrowsError(try AppUpdateManifestValidator.validate(manifest))
    }

    private func fixtureManifest(
        marketingVersion: String = "1.1",
        buildNumber: Int
    ) throws -> AppUpdateManifest {
        let normalizedVersion = (marketingVersion.split(separator: ".").map(String.init)
            + Array(repeating: "0", count: 3)).prefix(3).joined(separator: ".")
        let releaseTag = "v\(normalizedVersion)"
        let assetName = "ForgePlay-\(marketingVersion)-\(buildNumber).dmg"
        return AppUpdateManifest(
            schema: "./current-release.schema.json",
            schemaVersion: 1,
            product: "ForgePlay",
            channel: "stable",
            marketingVersion: marketingVersion,
            buildNumber: buildNumber,
            releaseTag: releaseTag,
            publishedAt: "2026-08-11T03:57:08Z",
            minimumMacOSVersion: "26.0",
            releaseURL: try XCTUnwrap(URL(string: "https://github.com/Facta-Leopard/ForgePlay/releases/tag/\(releaseTag)")),
            download: .init(
                assetName: assetName,
                url: try XCTUnwrap(URL(string: "https://github.com/Facta-Leopard/ForgePlay/releases/download/\(releaseTag)/\(assetName)")),
                sha256: String(repeating: "a", count: 64),
                byteSize: 123
            )
        )
    }

    private func jsonResponse(
        for request: URLRequest,
        manifest: AppUpdateManifest
    ) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json; charset=utf-8"]
        ))
        return (response, try JSONEncoder().encode(manifest))
    }

    private func assertUpdateRequest(_ request: URLRequest) throws {
        XCTAssertEqual(request.url, AppUpdateService.manifestURL)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }
}

private final class AppUpdateURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: Handler?

    static func session(handler: @escaping Handler) -> URLSession {
        lock.lock()
        self.handler = handler
        lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppUpdateURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class AppUpdateStreamingProbe: @unchecked Sendable {
    struct Snapshot {
        var deliveredBytes: Int
        var wasStopped: Bool
    }

    private let lock = NSLock()
    private var deliveredBytes = 0
    private var wasStopped = false

    func recordDelivery(byteCount: Int) {
        lock.lock()
        deliveredBytes += byteCount
        lock.unlock()
    }

    func recordStop() {
        lock.lock()
        wasStopped = true
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(deliveredBytes: deliveredBytes, wasStopped: wasStopped)
    }
}

private final class AppUpdateStreamingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    private nonisolated(unsafe) static var declaredSize = 0
    private nonisolated(unsafe) static var probe: AppUpdateStreamingProbe?

    static func session(declaredSize: Int, probe: AppUpdateStreamingProbe) -> URLSession {
        stateLock.lock()
        self.declaredSize = declaredSize
        self.probe = probe
        stateLock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppUpdateStreamingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.stateLock.lock()
        let declaredSize = Self.declaredSize
        let probe = Self.probe
        Self.stateLock.unlock()
        guard let probe,
              let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                    "Content-Length": String(declaredSize)
                ]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) { [self] in
            let chunkSize = 4_096
            var delivered = 0
            while delivered < declaredSize {
                if probe.snapshot().wasStopped { return }
                let nextSize = min(chunkSize, declaredSize - delivered)
                client?.urlProtocol(self, didLoad: Data(repeating: 0, count: nextSize))
                probe.recordDelivery(byteCount: nextSize)
                delivered += nextSize
                Thread.sleep(forTimeInterval: 0.001)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.stateLock.lock()
        let probe = Self.probe
        Self.stateLock.unlock()
        probe?.recordStop()
    }
}
