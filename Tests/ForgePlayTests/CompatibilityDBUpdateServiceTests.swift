import CryptoKit
import SwiftData
import XCTest
@testable import ForgePlay

@MainActor
final class CompatibilityDBUpdateServiceTests: XCTestCase {
    func testDefaultRemoteUpdateSessionDoesNotUseSharedCacheCookiesOrCredentials() {
        let configuration = CompatibilityDBUpdateService.defaultRemoteUpdateSessionConfiguration()

        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 20)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 60)
    }

    func testValidatesSignedIndexAndRecipe() throws {
        let privateKey = P256.Signing.PrivateKey()
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let recipe = sampleRecipe()
        let recipeData = try recipeEncoder.encode(recipe)
        let descriptor = CompatibilityDBRecipeDescriptor(
            id: recipe.id,
            url: URL(string: "https://example.com/recipes/\(recipe.id).json")!,
            sha256: CompatibilityDBUpdateService.sha256Hex(recipeData),
            signature: sign(recipeData, privateKey: privateKey)
        )
        let payload = CompatibilityDBIndexPayload(
            schemaVersion: 1,
            databaseVersion: 2,
            generatedAt: nil,
            recipes: [descriptor]
        )
        let payloadData = try indexEncoder.encode(payload)
        let index = CompatibilityDBSignedIndex(
            payload: payload,
            signature: sign(payloadData, privateKey: privateKey)
        )
        let indexData = try indexEncoder.encode(index)

        let validatedIndex = try service.validateIndex(indexData)
        let validatedRecipe = try service.validateRecipe(data: recipeData, descriptor: descriptor)

        XCTAssertEqual(validatedIndex.payload.databaseVersion, 2)
        XCTAssertEqual(validatedRecipe.id, recipe.id)
    }

    func testRejectsTamperedRecipeData() throws {
        let privateKey = P256.Signing.PrivateKey()
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let recipeData = try recipeEncoder.encode(sampleRecipe())
        let descriptor = CompatibilityDBRecipeDescriptor(
            id: "steam-1",
            url: URL(string: "https://example.com/recipes/steam-1.json")!,
            sha256: CompatibilityDBUpdateService.sha256Hex(recipeData),
            signature: sign(recipeData, privateKey: privateKey)
        )
        let tamperedData = Data("{}".utf8)

        XCTAssertThrowsError(try service.validateRecipe(data: tamperedData, descriptor: descriptor)) { error in
            XCTAssertTrue(error is CompatibilityDBUpdateError)
        }
    }

    func testRejectsInsecureRecipeURL() throws {
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: P256.Signing.PrivateKey().publicKey.rawRepresentation
        )
        let descriptor = CompatibilityDBRecipeDescriptor(
            id: "steam-1",
            url: URL(string: "http://example.com/recipes/steam-1.json")!,
            sha256: "",
            signature: ""
        )

        XCTAssertThrowsError(try service.validateRecipeDescriptor(descriptor)) { error in
            guard case CompatibilityDBUpdateError.insecureRecipeURL("steam-1") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsInvalidFeedURLBeforeNetworkRequest() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let feedURL = URL(string: "https://user:pass@example.com/index.json")!
        let session = CompatibilityDBURLProtocol.session { _ in
            XCTFail("Invalid feed URL should be rejected before any network request")
            throw URLError(.badURL)
        }
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
            session: session
        )

        do {
            _ = try await service.update(from: feedURL, existingRecords: [])
            XCTFail("Expected update to reject feed URL with userinfo")
        } catch CompatibilityDBUpdateError.invalidFeedURL {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingSignatureVerifierRejectsUpdateBeforeNetworkRequest() async throws {
        let feedURL = URL(string: "https://example.com/index.json")!
        let session = CompatibilityDBURLProtocol.session { _ in
            XCTFail("Missing signature verifier should reject update before any network request")
            throw URLError(.badServerResponse)
        }
        let service = CompatibilityDBUpdateService(session: session)

        do {
            _ = try await service.update(from: feedURL, existingRecords: [])
            XCTFail("Expected update to reject missing signature verifier before network request")
        } catch CompatibilityDBUpdateError.signatureVerifierMissing {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidSignatureVerifierRejectsUpdateBeforeNetworkRequest() async throws {
        let feedURL = URL(string: "https://example.com/index.json")!
        let session = CompatibilityDBURLProtocol.session { _ in
            XCTFail("Invalid signature verifier should reject update before any network request")
            throw URLError(.badServerResponse)
        }
        let service = CompatibilityDBUpdateService(
            signatureVerifierConfiguration: .invalid("invalid fixture key"),
            session: session
        )

        do {
            _ = try await service.update(from: feedURL, existingRecords: [])
            XCTFail("Expected update to reject invalid signature verifier before network request")
        } catch CompatibilityDBUpdateError.invalidPublicKey {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUpdateRejectsConcurrentRequestAndClearsSingleFlightState() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let feedURL = URL(string: "https://example.com/index.json")!
        let requestStarted = expectation(description: "first compatibility DB request started")
        let releaseRequest = DispatchSemaphore(value: 0)
        let session = CompatibilityDBURLProtocol.session { _ in
            requestStarted.fulfill()
            _ = releaseRequest.wait(timeout: .now() + 5)
            throw URLError(.cancelled)
        }
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
            session: session
        )

        let firstUpdate = Task { () -> Bool in
            do {
                _ = try await service.update(from: feedURL, existingRecords: [])
                return true
            } catch {
                return false
            }
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        XCTAssertTrue(service.isUpdateInProgress)

        do {
            _ = try await service.update(from: feedURL, existingRecords: [])
            XCTFail("Expected the concurrent update to be rejected")
        } catch CompatibilityDBUpdateError.updateInProgress {
            // Expected.
        } catch {
            XCTFail("Unexpected concurrent-update error: \(error)")
        }

        releaseRequest.signal()
        let firstUpdateSucceeded = await firstUpdate.value
        XCTAssertFalse(firstUpdateSucceeded)
        XCTAssertFalse(service.isUpdateInProgress)
    }

    func testValidateFeedURLAllowsOnlyPublicHTTPSHostURL() throws {
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: P256.Signing.PrivateKey().publicKey.rawRepresentation
        )
        let valid = URL(string: "https://example.com/index.json?version=2")!
        let userInfo = URL(string: "https://user@example.com/index.json")!
        let fragment = URL(string: "https://example.com/index.json#token")!
        let sensitiveQuery = URL(string: "https://example.com/index.json?api_key=secret")!

        XCTAssertEqual(try service.validateFeedURL(valid).absoluteString, valid.absoluteString)
        XCTAssertThrowsError(try service.validateFeedURL(nil)) { error in
            guard case CompatibilityDBUpdateError.missingFeedURL = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try service.validateFeedURL(URL(string: "http://example.com/index.json")!)) { error in
            guard case CompatibilityDBUpdateError.insecureFeedURL = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        for invalid in [userInfo, fragment, sensitiveQuery] {
            XCTAssertThrowsError(try service.validateFeedURL(invalid)) { error in
                guard case CompatibilityDBUpdateError.invalidFeedURL = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testRejectsInvalidRecipeDescriptorMetadata() throws {
        let privateKey = P256.Signing.PrivateKey()
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let recipeData = try recipeEncoder.encode(sampleRecipe())
        let validSHA = CompatibilityDBUpdateService.sha256Hex(recipeData)
        let validSignature = sign(recipeData, privateKey: privateKey)

        let invalidID = CompatibilityDBRecipeDescriptor(
            id: "steam/1",
            url: URL(string: "https://example.com/recipes/steam-1.json")!,
            sha256: validSHA,
            signature: validSignature
        )
        let userInfoURL = CompatibilityDBRecipeDescriptor(
            id: "steam-1",
            url: URL(string: "https://user:pass@example.com/recipes/steam-1.json")!,
            sha256: validSHA,
            signature: validSignature
        )
        let sensitiveQueryURL = CompatibilityDBRecipeDescriptor(
            id: "steam-1",
            url: URL(string: "https://example.com/recipes/steam-1.json?access_token=secret")!,
            sha256: validSHA,
            signature: validSignature
        )
        let invalidSHA = CompatibilityDBRecipeDescriptor(
            id: "steam-1",
            url: URL(string: "https://example.com/recipes/steam-1.json")!,
            sha256: "not-a-sha",
            signature: validSignature
        )

        for descriptor in [invalidID, userInfoURL, sensitiveQueryURL, invalidSHA] {
            XCTAssertThrowsError(try service.validateRecipeDescriptor(descriptor)) { error in
                guard case CompatibilityDBUpdateError.invalidRecipeDescriptor = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testRejectsSignedIndexWithDuplicateRecipeDescriptors() throws {
        let privateKey = P256.Signing.PrivateKey()
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let recipeData = try recipeEncoder.encode(sampleRecipe())
        let descriptor = signedDescriptor(recipeData: recipeData, privateKey: privateKey)
        let payload = CompatibilityDBIndexPayload(
            schemaVersion: 1,
            databaseVersion: 2,
            generatedAt: nil,
            recipes: [descriptor, descriptor]
        )
        let index = signedIndex(payload: payload, privateKey: privateKey)

        XCTAssertThrowsError(try service.validateIndex(try indexEncoder.encode(index))) { error in
            guard case CompatibilityDBUpdateError.duplicateRecipeDescriptor("steam-1") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsSignedIndexWithTooManyRecipeDescriptors() throws {
        let privateKey = P256.Signing.PrivateKey()
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let descriptors = (0..<513).map { index in
            CompatibilityDBRecipeDescriptor(
                id: "steam-\(index)",
                url: URL(string: "https://example.com/recipes/steam-\(index).json")!,
                sha256: String(repeating: "a", count: 64),
                signature: ""
            )
        }
        let payload = CompatibilityDBIndexPayload(
            schemaVersion: 1,
            databaseVersion: 2,
            generatedAt: nil,
            recipes: descriptors
        )
        let index = signedIndex(payload: payload, privateKey: privateKey)

        XCTAssertThrowsError(try service.validateIndex(try indexEncoder.encode(index))) { error in
            guard case CompatibilityDBUpdateError.tooManyRecipes(513, let limit) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertLessThan(limit, 513)
        }
    }

    func testRejectsInvalidDERSignatureAsRecipeSignatureFailure() throws {
        let privateKey = P256.Signing.PrivateKey()
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let recipeData = try recipeEncoder.encode(sampleRecipe())
        let descriptor = CompatibilityDBRecipeDescriptor(
            id: "steam-1",
            url: URL(string: "https://example.com/recipes/steam-1.json")!,
            sha256: CompatibilityDBUpdateService.sha256Hex(recipeData),
            signature: Data("not-der".utf8).base64EncodedString()
        )

        XCTAssertThrowsError(try service.validateRecipe(data: recipeData, descriptor: descriptor)) { error in
            guard case CompatibilityDBUpdateError.invalidRecipeSignature("steam-1") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsUnsupportedSignedIndexSchemaVersion() throws {
        let privateKey = P256.Signing.PrivateKey()
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let payload = CompatibilityDBIndexPayload(
            schemaVersion: 2,
            databaseVersion: 2,
            generatedAt: nil,
            recipes: []
        )
        let payloadData = try indexEncoder.encode(payload)
        let index = CompatibilityDBSignedIndex(
            payload: payload,
            signature: sign(payloadData, privateKey: privateKey)
        )

        XCTAssertThrowsError(try service.validateIndex(try indexEncoder.encode(index))) { error in
            guard case CompatibilityDBUpdateError.unsupportedSchemaVersion(2) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsRecipeIdMismatch() throws {
        let privateKey = P256.Signing.PrivateKey()
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let recipe = sampleRecipe()
        let recipeData = try recipeEncoder.encode(recipe)
        let descriptor = CompatibilityDBRecipeDescriptor(
            id: "steam-other",
            url: URL(string: "https://example.com/recipes/steam-other.json")!,
            sha256: CompatibilityDBUpdateService.sha256Hex(recipeData),
            signature: sign(recipeData, privateKey: privateKey)
        )

        XCTAssertThrowsError(try service.validateRecipe(data: recipeData, descriptor: descriptor)) { error in
            guard case CompatibilityDBUpdateError.recipeIdMismatch("steam-other", "steam-1") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsSignedRecipeWithInvalidDomainFields() throws {
        let privateKey = P256.Signing.PrivateKey()
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        var recipe = sampleRecipe()
        recipe.confidence = 1.5
        recipe.launchOptions = ["-windowed", "; rm -rf /"]
        let recipeData = try recipeEncoder.encode(recipe)
        let descriptor = CompatibilityDBRecipeDescriptor(
            id: recipe.id,
            url: URL(string: "https://example.com/recipes/\(recipe.id).json")!,
            sha256: CompatibilityDBUpdateService.sha256Hex(recipeData),
            signature: sign(recipeData, privateKey: privateKey)
        )

        XCTAssertThrowsError(try service.validateRecipe(data: recipeData, descriptor: descriptor)) { error in
            guard case CompatibilityDBUpdateError.invalidRecipe("steam-1") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testUpdateStoresNormalizedRecipeFields() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let feedURL = URL(string: "https://example.com/index.json")!
        var recipe = sampleRecipe()
        recipe.name = "  Signed Test Game  "
        recipe.supportStatus = " Partial "
        recipe.beginnerSummary = " Runs with one runtime. "
        recipe.technicalSummary = " Signed test fixture. "
        recipe.launchOptions = [" -Windowed ", "-windowed", "-force-d3d11"]
        recipe.notes = [" First note ", "First note", "  "]
        let recipeData = try recipeEncoder.encode(recipe)
        let descriptor = signedDescriptor(recipeData: recipeData, privateKey: privateKey)
        let index = signedIndex(
            payload: CompatibilityDBIndexPayload(
                schemaVersion: 1,
                databaseVersion: 7,
                generatedAt: nil,
                recipes: [descriptor]
            ),
            privateKey: privateKey
        )
        let indexData = try indexEncoder.encode(index)
        let session = CompatibilityDBURLProtocol.session { request in
            let url = try XCTUnwrap(request.url)
            let data = url.lastPathComponent == "index.json" ? indexData : recipeData
            return (
                try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)),
                data
            )
        }
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
            session: session
        )

        let (result, records) = try await service.update(from: feedURL, existingRecords: [])
        let record = try XCTUnwrap(records.first)
        let storedRecipe = try XCTUnwrap(CompatibilityService().decode(record))

        XCTAssertEqual(result.databaseVersion, 7)
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.updatedCount, 0)
        XCTAssertEqual(storedRecipe.name, "Signed Test Game")
        XCTAssertEqual(storedRecipe.supportStatus, "partial")
        XCTAssertEqual(storedRecipe.launchOptions, ["-windowed", "-force-d3d11"])
        XCTAssertEqual(storedRecipe.notes, ["First note"])
    }

    func testUpdateRejectsMultipleRecipesForOneSteamAppID() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let fixture = try signedFeed(
            recipes: [
                sampleRecipe(id: "steam-1-a", steamAppID: "1", name: "First"),
                sampleRecipe(id: "steam-1-b", steamAppID: "1", name: "Second")
            ],
            databaseVersion: 8,
            privateKey: privateKey
        )
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation:
                privateKey.publicKey.rawRepresentation,
            session: session(for: fixture)
        )

        do {
            _ = try await service.update(
                from: URL(string: "https://example.com/index.json")!,
                existingRecords: []
            )
            XCTFail("Expected duplicate Steam App ID rejection")
        } catch CompatibilityDBUpdateError.duplicateSteamAppID("1") {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUpdateCountsExistingRecordsAsUpdated() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let feedURL = URL(string: "https://example.com/index.json")!
        var existingRecipe = sampleRecipe()
        existingRecipe.name = "Existing Name"
        let existingRecord = try CompatibilityRecipeRecordProjection.makeRecord(from: existingRecipe)
        var updatedRecipe = sampleRecipe()
        updatedRecipe.name = "Updated Name"
        updatedRecipe.supportStatus = "partial"
        updatedRecipe.confidence = 0.95
        let recipeData = try recipeEncoder.encode(updatedRecipe)
        let descriptor = signedDescriptor(recipeData: recipeData, privateKey: privateKey)
        let index = signedIndex(
            payload: CompatibilityDBIndexPayload(
                schemaVersion: 1,
                databaseVersion: 8,
                generatedAt: nil,
                recipes: [descriptor]
            ),
            privateKey: privateKey
        )
        let indexData = try indexEncoder.encode(index)
        let session = CompatibilityDBURLProtocol.session { request in
            let url = try XCTUnwrap(request.url)
            let data = url.lastPathComponent == "index.json" ? indexData : recipeData
            return (
                try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)),
                data
            )
        }
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
            session: session
        )

        let (result, records) = try await service.update(from: feedURL, existingRecords: [existingRecord])
        let storedRecipe = try XCTUnwrap(CompatibilityService().decode(existingRecord))

        XCTAssertEqual(result.databaseVersion, 8)
        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.updatedCount, 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records.first === existingRecord)
        XCTAssertEqual(existingRecord.name, "Updated Name")
        XCTAssertEqual(existingRecord.supportStatus, "partial")
        XCTAssertEqual(existingRecord.confidence, 0.95)
        XCTAssertEqual(storedRecipe.name, "Updated Name")
    }

    func testUpdateRejectsSignedDatabaseVersionRollbackBeforeRecipeFetch() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let feedURL = URL(string: "https://example.com/index.json")!
        let currentFeed = try signedFeed(
            recipes: [sampleRecipe()],
            databaseVersion: 10,
            privateKey: privateKey
        )
        let currentService = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
            session: session(for: currentFeed)
        )
        let (_, currentRecords) = try await currentService.update(from: feedURL, existingRecords: [])
        let persistedRecords = currentRecords.map(CompatibilityRecipeRecordProjection.makeDetachedRecord)

        let rollbackFeed = try signedFeed(
            recipes: [sampleRecipe()],
            databaseVersion: 9,
            privateKey: privateKey
        )
        var recipeFetchCount = 0
        let rollbackService = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
            session: session(for: rollbackFeed) { url in
                if url.lastPathComponent != "index.json" {
                    recipeFetchCount += 1
                }
            }
        )

        do {
            _ = try await rollbackService.update(from: feedURL, existingRecords: persistedRecords)
            XCTFail("Expected a signed older databaseVersion to be rejected")
        } catch CompatibilityDBVersionPolicyError.rollback(let current, let received) {
            XCTAssertEqual(current, 10)
            XCTAssertEqual(received, 9)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(recipeFetchCount, 0)
    }

    func testUpdateRejectsSameDatabaseVersionWithDifferentSignedPayload() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let feedURL = URL(string: "https://example.com/index.json")!
        let currentFeed = try signedFeed(
            recipes: [sampleRecipe()],
            databaseVersion: 10,
            privateKey: privateKey
        )
        let currentService = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
            session: session(for: currentFeed)
        )
        let (_, currentRecords) = try await currentService.update(from: feedURL, existingRecords: [])

        var conflictingRecipe = sampleRecipe()
        conflictingRecipe.name = "Different Signed Payload"
        let conflictingFeed = try signedFeed(
            recipes: [conflictingRecipe],
            databaseVersion: 10,
            privateKey: privateKey
        )
        var recipeFetchCount = 0
        let conflictingService = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
            session: session(for: conflictingFeed) { url in
                if url.lastPathComponent != "index.json" {
                    recipeFetchCount += 1
                }
            }
        )

        do {
            _ = try await conflictingService.update(from: feedURL, existingRecords: currentRecords)
            XCTFail("Expected databaseVersion reuse with a different payload to be rejected")
        } catch CompatibilityDBVersionPolicyError.versionReuseWithDifferentPayload(let version) {
            XCTAssertEqual(version, 10)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(recipeFetchCount, 0)
    }

    func testUpdateAllowsIdempotentReplayOfSameVersionAndPayload() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let feedURL = URL(string: "https://example.com/index.json")!
        let feed = try signedFeed(
            recipes: [sampleRecipe()],
            databaseVersion: 10,
            privateKey: privateKey
        )
        let firstService = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
            session: session(for: feed)
        )
        let (_, firstRecords) = try await firstService.update(from: feedURL, existingRecords: [])
        let replayService = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
            session: session(for: feed)
        )

        let (result, replayedRecords) = try await replayService.update(
            from: feedURL,
            existingRecords: firstRecords.map(CompatibilityRecipeRecordProjection.makeDetachedRecord)
        )

        XCTAssertEqual(result.databaseVersion, 10)
        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.updatedCount, 1)
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(replayedRecords.map(\.recipeId), ["steam-1"])
    }

    func testUpdateTreatsRecipeListAsAuthoritativeSnapshotAndReportsOmittedRecipeRemoval() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let feedURL = URL(string: "https://example.com/index.json")!
        let initialFeed = try signedFeed(
            recipes: [
                sampleRecipe(id: "steam-1", steamAppID: "1", name: "Keep"),
                sampleRecipe(id: "steam-2", steamAppID: "2", name: "Revoke")
            ],
            databaseVersion: 20,
            privateKey: privateKey
        )
        let initialService = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
            session: session(for: initialFeed)
        )
        let (_, initialRecords) = try await initialService.update(from: feedURL, existingRecords: [])

        let nextFeed = try signedFeed(
            recipes: [sampleRecipe(id: "steam-1", steamAppID: "1", name: "Keep Updated")],
            databaseVersion: 21,
            privateKey: privateKey
        )
        let nextService = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
            session: session(for: nextFeed)
        )

        let (result, snapshotRecords) = try await nextService.update(
            from: feedURL,
            existingRecords: initialRecords
        )

        XCTAssertEqual(result.databaseVersion, 21)
        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.updatedCount, 1)
        XCTAssertEqual(result.removedRecipeIDs, ["steam-2"])
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(snapshotRecords.map(\.recipeId), ["steam-1"])
        XCTAssertEqual(snapshotRecords.first?.name, "Keep Updated")
    }

    func testModelContextAppliesAuthoritativeCompatibilitySnapshotIncludingRemoval() throws {
        let container = try ForgePlayApp.makeModelContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        context.insert(try CompatibilityRecipeRecordProjection.makeRecord(from: sampleRecipe(
            id: "steam-1",
            steamAppID: "1",
            name: "Old Name"
        )))
        context.insert(try CompatibilityRecipeRecordProjection.makeRecord(from: sampleRecipe(
            id: "steam-2",
            steamAppID: "2",
            name: "Revoked"
        )))
        try context.save()
        let incoming = [
            try CompatibilityRecipeRecordProjection.makeRecord(from: sampleRecipe(
                id: "steam-1",
                steamAppID: "1",
                name: "Updated Name"
            )),
            try CompatibilityRecipeRecordProjection.makeRecord(from: sampleRecipe(
                id: "steam-3",
                steamAppID: "3",
                name: "New Recipe"
            ))
        ]

        let result = try context.applyCompatibilityRecipeSnapshot(incoming)
        try context.save()
        let stored = try context.fetch(FetchDescriptor<CompatibilityRecipeRecord>())
            .sorted { $0.recipeId < $1.recipeId }

        XCTAssertEqual(result.insertedCount, 1)
        XCTAssertEqual(result.updatedCount, 1)
        XCTAssertEqual(result.removedRecipeIDs, ["steam-2"])
        XCTAssertEqual(stored.map(\.recipeId), ["steam-1", "steam-3"])
        XCTAssertEqual(stored.first?.name, "Updated Name")
    }

    func testRejectsSignedIndexWithNonPositiveDatabaseVersion() throws {
        let privateKey = P256.Signing.PrivateKey()
        let recipeData = try recipeEncoder.encode(sampleRecipe())
        let descriptor = signedDescriptor(recipeData: recipeData, privateKey: privateKey)
        let payload = CompatibilityDBIndexPayload(
            schemaVersion: 1,
            databaseVersion: 0,
            generatedAt: nil,
            recipes: [descriptor]
        )
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )

        XCTAssertThrowsError(try service.validateIndex(try indexEncoder.encode(signedIndex(
            payload: payload,
            privateKey: privateKey
        )))) { error in
            guard case CompatibilityDBVersionPolicyError.invalidDatabaseVersion(0) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsEmptyAuthoritativeSnapshotMatchingProductionSignerContract() throws {
        let privateKey = P256.Signing.PrivateKey()
        let payload = CompatibilityDBIndexPayload(
            schemaVersion: 1,
            databaseVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            recipes: []
        )
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )

        XCTAssertThrowsError(try service.validateIndex(try indexEncoder.encode(signedIndex(
            payload: payload,
            privateKey: privateKey
        )))) { error in
            guard case CompatibilityDBVersionPolicyError.emptyAuthoritativeSnapshot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testUpdateRejectsNonSuccessHTTPStatus() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let feedURL = URL(string: "https://example.com/index.json")!
        let session = CompatibilityDBURLProtocol.session { request in
            let url = try XCTUnwrap(request.url)
            return (
                try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)),
                Data("{}".utf8)
            )
        }
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
            session: session
        )

        do {
            _ = try await service.update(from: feedURL, existingRecords: [])
            XCTFail("Expected update to reject non-success HTTP status")
        } catch CompatibilityDBUpdateError.invalidHTTPStatus("index.json", 503) {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUpdateRejectsInsecureResolvedURL() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let feedURL = URL(string: "https://example.com/index.json")!
        let session = CompatibilityDBURLProtocol.session { _ in
            (
                try XCTUnwrap(HTTPURLResponse(
                    url: URL(string: "http://example.com/index.json")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )),
                Data("{}".utf8)
            )
        }
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
            session: session
        )

        do {
            _ = try await service.update(from: feedURL, existingRecords: [])
            XCTFail("Expected update to reject insecure resolved URL")
        } catch CompatibilityDBUpdateError.insecureResolvedURL("index.json") {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUpdateRejectsResolvedURLWithUserInfoOrFragment() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let feedURL = URL(string: "https://example.com/index.json")!
        let invalidResolvedURLs = [
            URL(string: "https://user:pass@example.com/index.json")!,
            URL(string: "https://example.com/index.json#token")!,
            URL(string: "https://example.com/index.json?session_id=secret")!
        ]

        for resolvedURL in invalidResolvedURLs {
            let session = CompatibilityDBURLProtocol.session { _ in
                (
                    try XCTUnwrap(HTTPURLResponse(
                        url: resolvedURL,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )),
                    Data("{}".utf8)
                )
            }
            let service = CompatibilityDBUpdateService(
                trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
                session: session
            )

            do {
                _ = try await service.update(from: feedURL, existingRecords: [])
                XCTFail("Expected update to reject resolved URL: \(resolvedURL.absoluteString)")
            } catch CompatibilityDBUpdateError.insecureResolvedURL("index.json") {
                // Expected.
            } catch {
                XCTFail("Unexpected error for \(resolvedURL.absoluteString): \(error)")
            }
        }
    }

    func testUpdateRejectsOversizedIndexResponse() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let feedURL = URL(string: "https://example.com/index.json")!
        let session = CompatibilityDBURLProtocol.session { request in
            let url = try XCTUnwrap(request.url)
            return (
                try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)),
                Data(repeating: UInt8(ascii: "x"), count: 600 * 1024)
            )
        }
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
            session: session
        )

        do {
            _ = try await service.update(from: feedURL, existingRecords: [])
            XCTFail("Expected update to reject oversized index response")
        } catch CompatibilityDBUpdateError.responseTooLarge("index.json", let byteCount, let limit) {
            // A declared Content-Length can report the server's complete size
            // up front; otherwise streaming stops at the first byte over the
            // bound. Neither path requires buffering the complete response.
            XCTAssertLessThan(limit, byteCount)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUpdateRejectsDuplicateExistingRecipeRecordsBeforeNetworkRequest() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let feedURL = URL(string: "https://example.com/index.json")!
        let session = CompatibilityDBURLProtocol.session { _ in
            XCTFail("Duplicate stored recipe records should be rejected before network fetch")
            throw URLError(.badServerResponse)
        }
        let service = CompatibilityDBUpdateService(
            trustedPublicKeyRawRepresentation: privateKey.publicKey.rawRepresentation,
            session: session
        )
        let firstRecord = CompatibilityRecipeRecord(
            recipeId: "steam-1",
            steamAppId: "1",
            name: "First",
            supportStatus: "playable",
            confidence: 0.8,
            recipeJSON: "{}"
        )
        let secondRecord = CompatibilityRecipeRecord(
            recipeId: "steam-1",
            steamAppId: "1",
            name: "Duplicate",
            supportStatus: "playable",
            confidence: 0.8,
            recipeJSON: "{}"
        )

        do {
            _ = try await service.update(from: feedURL, existingRecords: [firstRecord, secondRecord])
            XCTFail("Expected update to reject duplicate stored recipe records")
        } catch CompatibilityDBUpdateError.duplicateStoredRecipeRecord("steam-1") {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingSignatureVerifierMessageDoesNotDescribeCommercialBuildAsDevelopmentBuild() throws {
        let service = CompatibilityDBUpdateService()
        let recipeData = try recipeEncoder.encode(sampleRecipe())
        let descriptor = CompatibilityDBRecipeDescriptor(
            id: "steam-1",
            url: URL(string: "https://example.com/recipes/steam-1.json")!,
            sha256: CompatibilityDBUpdateService.sha256Hex(recipeData),
            signature: ""
        )

        XCTAssertThrowsError(try service.validateRecipe(data: recipeData, descriptor: descriptor)) { error in
            guard let updateError = error as? CompatibilityDBUpdateError else {
                return XCTFail("Unexpected error: \(error)")
            }
            guard case .signatureVerifierMissing = updateError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(updateError.localizedDescription.contains("개발 빌드"))
        }
    }

    func testInvalidSignatureVerifierConfigurationIsNotTreatedAsMissingKey() throws {
        let service = CompatibilityDBUpdateService(
            signatureVerifierConfiguration: .invalid("invalid fixture key")
        )
        let recipeData = try recipeEncoder.encode(sampleRecipe())
        let descriptor = CompatibilityDBRecipeDescriptor(
            id: "steam-1",
            url: URL(string: "https://example.com/recipes/steam-1.json")!,
            sha256: CompatibilityDBUpdateService.sha256Hex(recipeData),
            signature: ""
        )

        XCTAssertFalse(service.canApplyRemoteUpdates)
        guard case .invalidPublicKey? = service.remoteUpdateUnavailableError else {
            return XCTFail("Expected invalid public key unavailable error")
        }
        XCTAssertThrowsError(try service.validateRecipe(data: recipeData, descriptor: descriptor)) { error in
            guard case CompatibilityDBUpdateError.invalidPublicKey = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private struct SignedFeedFixture {
        var indexData: Data
        var recipeDataByURL: [URL: Data]
    }

    private func signedFeed(
        recipes: [CompatibilityRecipe],
        databaseVersion: Int,
        generatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        privateKey: P256.Signing.PrivateKey
    ) throws -> SignedFeedFixture {
        var recipeDataByURL: [URL: Data] = [:]
        let descriptors = try recipes.map { recipe in
            let data = try recipeEncoder.encode(recipe)
            let url = URL(string: "https://example.com/recipes/\(recipe.id).json")!
            recipeDataByURL[url] = data
            return signedDescriptor(
                id: recipe.id,
                url: url,
                recipeData: data,
                privateKey: privateKey
            )
        }
        let payload = CompatibilityDBIndexPayload(
            schemaVersion: 1,
            databaseVersion: databaseVersion,
            generatedAt: generatedAt,
            recipes: descriptors
        )
        return SignedFeedFixture(
            indexData: try indexEncoder.encode(signedIndex(payload: payload, privateKey: privateKey)),
            recipeDataByURL: recipeDataByURL
        )
    }

    private func session(
        for fixture: SignedFeedFixture,
        requestObserver: ((URL) -> Void)? = nil
    ) -> URLSession {
        CompatibilityDBURLProtocol.session { request in
            let url = try XCTUnwrap(request.url)
            requestObserver?(url)
            let data: Data
            if url.lastPathComponent == "index.json" {
                data = fixture.indexData
            } else {
                data = try XCTUnwrap(fixture.recipeDataByURL[url])
            }
            return (
                try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)),
                data
            )
        }
    }

    private func sampleRecipe(
        id: String = "steam-1",
        steamAppID: String = "1",
        name: String = "Signed Test Game"
    ) -> CompatibilityRecipe {
        CompatibilityRecipe(
            id: id,
            steamAppId: steamAppID,
            name: name,
            supportStatus: "playable",
            beginnerSummary: "Runs with one runtime.",
            technicalSummary: "Signed test fixture.",
            confidence: 0.8,
            requiredRuntimes: [.vcrun2022],
            launchOptions: [],
            notes: [],
            lastVerifiedAt: nil
        )
    }

    private func sign(_ data: Data, privateKey: P256.Signing.PrivateKey) -> String {
        let signature = try! privateKey.signature(for: data)
        return signature.derRepresentation.base64EncodedString()
    }

    private func signedDescriptor(
        id: String = "steam-1",
        url: URL = URL(string: "https://example.com/recipes/steam-1.json")!,
        recipeData: Data,
        privateKey: P256.Signing.PrivateKey
    ) -> CompatibilityDBRecipeDescriptor {
        CompatibilityDBRecipeDescriptor(
            id: id,
            url: url,
            sha256: CompatibilityDBUpdateService.sha256Hex(recipeData),
            signature: sign(recipeData, privateKey: privateKey)
        )
    }

    private func signedIndex(
        payload: CompatibilityDBIndexPayload,
        privateKey: P256.Signing.PrivateKey
    ) -> CompatibilityDBSignedIndex {
        let payloadData = try! indexEncoder.encode(payload)
        return CompatibilityDBSignedIndex(
            payload: payload,
            signature: sign(payloadData, privateKey: privateKey)
        )
    }

    private var indexEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var recipeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private final class CompatibilityDBURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private nonisolated(unsafe) static var handler: Handler?

    static func session(handler: @escaping Handler) -> URLSession {
        self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompatibilityDBURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
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
