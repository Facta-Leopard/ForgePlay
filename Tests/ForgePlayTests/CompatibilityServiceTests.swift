import XCTest
@testable import ForgePlay

final class CompatibilityServiceTests: XCTestCase {
    func testDecodesBundledRecipeShape() throws {
        let recipe = try XCTUnwrap(
            try CompatibilityService()
                .loadBundledRecipes(bundle: .main)
                .first { $0.id == "steam-1245620-elden-ring" }
        )

        XCTAssertEqual(recipe.steamAppId, "1245620")
        XCTAssertTrue(recipe.requiredRuntimes.contains(.vcrun2022))
        XCTAssertEqual(recipe.preferredGraphicsBackend, .d3dMetal)
    }

    func testImportBundledRecipesStoresDecodableRecipeJSON() throws {
        let service = CompatibilityService()

        let records = try service.importBundledRecipes(into: [], bundle: .main)
        let record = try XCTUnwrap(records.first { $0.recipeId == "steam-1245620-elden-ring" })
        let decodedRecipe = try XCTUnwrap(service.decode(record))

        XCTAssertEqual(decodedRecipe.id, record.recipeId)
        XCTAssertEqual(decodedRecipe.steamAppId, "1245620")
        XCTAssertEqual(decodedRecipe.preferredGraphicsBackend, .d3dMetal)
        XCTAssertFalse(record.recipeJSON.isEmpty)
    }

    func testRecipeLoadingDeduplicatesDuplicateRecipeFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCompatibilityTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appending(path: "first.json")
        let duplicate = root.appending(path: "duplicate.json")

        try recipeData(id: "steam-1", name: "First").write(to: first)
        try recipeData(id: "steam-1", name: "Duplicate").write(to: duplicate)

        let recipes = try CompatibilityService().loadRecipes(at: [first, duplicate])

        XCTAssertEqual(recipes.map(\.id), ["steam-1"])
        XCTAssertEqual(recipes.first?.name, "First")
    }

    func testRecipeLoadingRejectsUnsafeAndOversizedRecipeFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCompatibilityTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalRecipe = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalRecipe-\(UUID().uuidString).json")
        let externalHardlinkRecipe = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalHardlinkRecipe-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalRecipe)
            try? FileManager.default.removeItem(at: externalHardlinkRecipe)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let linked = root.appending(path: "linked.json")
        let hardlinked = root.appending(path: "hardlinked.json")
        let oversized = root.appending(path: "oversized.json")
        try recipeData(id: "steam-linked", name: "Linked").write(to: externalRecipe)
        try recipeData(id: "steam-hardlinked", name: "Hardlinked").write(to: externalHardlinkRecipe)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: externalRecipe)
        try FileManager.default.linkItem(at: externalHardlinkRecipe, to: hardlinked)
        try Data(repeating: UInt8(ascii: "x"), count: 300 * 1024).write(to: oversized)

        XCTAssertThrowsError(try CompatibilityService().loadRecipes(at: [linked])) { error in
            guard case CompatibilityServiceError.unsafeRecipeFile(let url) = error else {
                return XCTFail("Expected unsafeRecipeFile, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, linked.standardizedFileURL.path)
        }
        XCTAssertThrowsError(try CompatibilityService().loadRecipes(at: [hardlinked])) { error in
            guard case CompatibilityServiceError.unsafeRecipeFile(let url) = error else {
                return XCTFail("Expected unsafeRecipeFile, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, hardlinked.standardizedFileURL.path)
        }
        XCTAssertThrowsError(try CompatibilityService().loadRecipes(at: [oversized])) { error in
            guard case CompatibilityServiceError.recipeTooLarge(let url, _, _) = error else {
                return XCTFail("Expected recipeTooLarge, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL.path, oversized.standardizedFileURL.path)
        }
    }

    func testRecipeLoadingRejectsInvalidDomainFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCompatibilityTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let unsafeStatus = root.appending(path: "unsafe-status.json")
        let unsafeLaunchOption = root.appending(path: "unsafe-launch-option.json")
        let unsafeConfidence = root.appending(path: "unsafe-confidence.json")

        try recipeData(id: "steam-1", name: "Unsafe Status", supportStatus: "beta").write(to: unsafeStatus)
        try recipeData(id: "steam-2", name: "Unsafe Launch", launchOptions: ["-windowed", "; rm -rf /"]).write(to: unsafeLaunchOption)
        try recipeData(id: "steam-3", name: "Unsafe Confidence", confidence: 1.5).write(to: unsafeConfidence)

        for url in [unsafeStatus, unsafeLaunchOption, unsafeConfidence] {
            XCTAssertThrowsError(try CompatibilityService().loadRecipes(at: [url])) { error in
                guard case CompatibilityServiceError.invalidRecipe(let failedURL) = error else {
                    return XCTFail("Expected invalidRecipe, got \(error)")
                }
                XCTAssertEqual(failedURL.standardizedFileURL.path, url.standardizedFileURL.path)
            }
        }
    }

    func testRecipeURLDiscoverySkipsSymlinkRecipeDirectoryAndUnrelatedJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCompatibilityTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let externalRecipes = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayExternalRecipes-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalRecipes)
        }

        let recipes = root.appending(path: "CompatibilityDB/recipes", directoryHint: .isDirectory)
        let linkedRecipes = root.appending(path: "Linked/recipes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recipes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalRecipes, withIntermediateDirectories: true)
        try recipeData(id: "steam-1", name: "First").write(to: recipes.appending(path: "steam-1.json"))
        try recipeData(id: "steam-linked", name: "Linked").write(to: externalRecipes.appending(path: "steam-linked.json"))
        try FileManager.default.createDirectory(
            at: linkedRecipes.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: linkedRecipes, withDestinationURL: externalRecipes)
        try Data("{}".utf8).write(to: root.appending(path: "Contents.json"))

        let service = CompatibilityService()
        let urls = try service.recipeURLs(inResourceRoot: root)
        let loadedRecipes = try service.loadRecipes(at: urls)

        XCTAssertFalse(urls.map(\.lastPathComponent).contains("steam-linked.json"))
        XCTAssertFalse(urls.map(\.lastPathComponent).contains("Contents.json"))
        XCTAssertEqual(loadedRecipes.map(\.id), ["steam-1"])
    }

    func testStoredRecipeDecodeRejectsOversizedRecipeJSON() {
        let record = CompatibilityRecipeRecord(
            recipeId: "steam-1",
            steamAppId: "1",
            name: "Oversized",
            supportStatus: "playable",
            confidence: 0.8,
            recipeJSON: String(repeating: "x", count: 300 * 1024)
        )

        XCTAssertNil(CompatibilityService().decode(record))
        XCTAssertThrowsError(try CompatibilityService().requiredDecodedRecipe(record)) { error in
            guard case CompatibilityServiceError.storedRecipeTooLarge(let id, let byteCount, let limit) = error else {
                return XCTFail("Expected storedRecipeTooLarge, got \(error)")
            }
            XCTAssertEqual(id, "steam-1")
            XCTAssertEqual(byteCount, 300 * 1024)
            XCTAssertLessThan(limit, byteCount)
        }
    }

    func testStoredRecipeRequiredDecodeSurfacesInvalidJSON() {
        let record = CompatibilityRecipeRecord(
            recipeId: "steam-1",
            steamAppId: "1",
            name: "Broken",
            supportStatus: "playable",
            confidence: 0.8,
            recipeJSON: "{"
        )

        XCTAssertNil(CompatibilityService().decode(record))
        XCTAssertThrowsError(try CompatibilityService().requiredDecodedRecipe(record)) { error in
            guard case CompatibilityServiceError.storedRecipeDecodeFailed(let id) = error else {
                return XCTFail("Expected storedRecipeDecodeFailed, got \(error)")
            }
            XCTAssertEqual(id, "steam-1")
        }
    }

    func testStoredRecipeDecodeRejectsRecordIdentityMismatch() throws {
        let json = try recipeJSONString(id: "steam-2", name: "Other")
        let record = CompatibilityRecipeRecord(
            recipeId: "steam-1",
            steamAppId: "1",
            name: "Stored",
            supportStatus: "playable",
            confidence: 0.8,
            recipeJSON: json
        )

        XCTAssertNil(CompatibilityService().decode(record))
        XCTAssertThrowsError(try CompatibilityService().requiredDecodedRecipe(record)) { error in
            guard case CompatibilityServiceError.storedRecipeRecordMismatch(let id) = error else {
                return XCTFail("Expected storedRecipeRecordMismatch, got \(error)")
            }
            XCTAssertEqual(id, "steam-1")
        }
    }

    func testStoredRecipeDecodeRejectsInvalidDomainFields() throws {
        let json = try recipeJSONString(id: "steam-1", name: "Stored", supportStatus: "unreviewed")
        let record = CompatibilityRecipeRecord(
            recipeId: "steam-1",
            steamAppId: "1",
            name: "Stored",
            supportStatus: "playable",
            confidence: 0.8,
            recipeJSON: json
        )

        XCTAssertNil(CompatibilityService().decode(record))
        XCTAssertThrowsError(try CompatibilityService().requiredDecodedRecipe(record)) { error in
            guard case CompatibilityServiceError.storedRecipeInvalid(let id) = error else {
                return XCTFail("Expected storedRecipeInvalid, got \(error)")
            }
            XCTAssertEqual(id, "steam-1")
        }
    }

    func testStoredRecipeLookupUsesDecodedRecipeInsteadOfCorruptRecordFields() throws {
        let json = try recipeJSONString(id: "steam-2", name: "Other Game")
        let record = CompatibilityRecipeRecord(
            recipeId: "steam-2",
            steamAppId: nil,
            name: "Target Game",
            supportStatus: "playable",
            confidence: 0.8,
            recipeJSON: json
        )
        let game = SteamGame(
            steamAppId: "999999999",
            name: "Target Game",
            installDir: "Target Game",
            libraryPath: "/tmp",
            manifestPath: "/tmp/appmanifest_999999999.acf",
            sizeOnDisk: 1,
            lastUpdated: nil
        )

        XCTAssertNil(try CompatibilityService().requiredRecipe(for: game, records: [record]))
    }

    func testStoredRecipeLookupSurfacesCorruptStoredRecord() throws {
        let record = CompatibilityRecipeRecord(
            recipeId: "steam-1",
            steamAppId: "1",
            name: "Broken",
            supportStatus: "playable",
            confidence: 0.8,
            recipeJSON: "{"
        )
        let game = SteamGame(
            steamAppId: "1",
            name: "Broken",
            installDir: "Broken",
            libraryPath: "/tmp",
            manifestPath: "/tmp/appmanifest_1.acf",
            sizeOnDisk: 1,
            lastUpdated: nil
        )

        XCTAssertThrowsError(try CompatibilityService().requiredRecipe(for: game, records: [record])) { error in
            guard case CompatibilityServiceError.storedRecipeDecodeFailed(let id) = error else {
                return XCTFail("Expected storedRecipeDecodeFailed, got \(error)")
            }
            XCTAssertEqual(id, "steam-1")
        }
    }

    func testDiagnosticGuidanceRecipePrefersValidatedStoredRecipeOverBundledFallback() throws {
        let storedRecipe = CompatibilityRecipe(
            id: "steam-1245620-signed-guidance",
            steamAppId: "1245620",
            name: "Elden Ring signed guidance",
            supportStatus: "playable",
            beginnerSummary: "Use the signed stored guidance.",
            technicalSummary: "Stored diagnostic guidance fixture.",
            confidence: 0.9,
            requiredRuntimes: [.vcrun2022],
            launchOptions: ["-windowed"],
            notes: [],
            lastVerifiedAt: Date(timeIntervalSince1970: 100)
        )
        let storedRecord = try CompatibilityRecipeRecordProjection.makeRecord(
            from: storedRecipe
        )
        let game = SteamGame(
            steamAppId: "1245620",
            name: "ELDEN RING",
            installDir: "ELDEN RING",
            libraryPath: "/tmp",
            manifestPath: "/tmp/appmanifest_1245620.acf",
            sizeOnDisk: 1,
            lastUpdated: nil
        )

        let resolved = try CompatibilityService().diagnosticGuidanceRecipe(
            for: game,
            storedRecords: [storedRecord],
            bundle: .main
        )

        XCTAssertEqual(resolved?.id, storedRecipe.id)
        XCTAssertEqual(resolved?.beginnerSummary, storedRecipe.beginnerSummary)
    }

    func testDiagnosticGuidanceUsesExactSteamAppIDNotMatchingTitle() throws {
        let otherRecipe = CompatibilityRecipe(
            id: "steam-999-other-title-collision",
            steamAppId: "999",
            name: "Same Display Name",
            supportStatus: "playable",
            beginnerSummary: "Wrong app ID.",
            technicalSummary: "Must not join by title.",
            confidence: 0.8,
            requiredRuntimes: [],
            launchOptions: [],
            notes: [],
            lastVerifiedAt: nil
        )
        let game = SteamGame(
            steamAppId: "998",
            name: "Same Display Name",
            installDir: "Same Display Name",
            libraryPath: "/tmp",
            manifestPath: "/tmp/appmanifest_998.acf",
            sizeOnDisk: 1,
            lastUpdated: nil
        )

        let resolved = try CompatibilityService().diagnosticGuidanceRecipe(
            for: game,
            storedRecords: [
                try CompatibilityRecipeRecordProjection.makeRecord(
                    from: otherRecipe
                )
            ],
            bundle: .main
        )

        XCTAssertNil(resolved)
    }

    func testUnrelatedInvalidStoredRecipeDoesNotBlockExactAppIDCandidate() throws {
        let exactRecipe = CompatibilityRecipe(
            id: "steam-998-exact",
            steamAppId: "998",
            name: "Exact",
            supportStatus: "playable",
            beginnerSummary: "Exact guidance.",
            technicalSummary: "Exact app ID fixture.",
            confidence: 0.8,
            requiredRuntimes: [],
            launchOptions: [],
            notes: [],
            lastVerifiedAt: nil
        )
        let unrelatedInvalid = CompatibilityRecipeRecord(
            recipeId: "steam-997-invalid",
            steamAppId: "997",
            name: "Invalid",
            supportStatus: "playable",
            confidence: 0.5,
            recipeJSON: "not-json"
        )
        let game = SteamGame(
            steamAppId: "998",
            name: "Exact",
            installDir: "Exact",
            libraryPath: "/tmp",
            manifestPath: "/tmp/appmanifest_998.acf",
            sizeOnDisk: 1,
            lastUpdated: nil
        )

        let resolved = try CompatibilityService().diagnosticGuidanceRecipe(
            for: game,
            storedRecords: [
                unrelatedInvalid,
                try CompatibilityRecipeRecordProjection.makeRecord(
                    from: exactRecipe
                )
            ],
            bundle: .main
        )

        XCTAssertEqual(resolved?.id, exactRecipe.id)
    }

    func testDuplicateStoredRecipesForExactSteamAppIDFailClosed() throws {
        func recipe(id: String) -> CompatibilityRecipe {
            CompatibilityRecipe(
                id: id,
                steamAppId: "998",
                name: "Duplicate",
                supportStatus: "playable",
                beginnerSummary: "Duplicate guidance.",
                technicalSummary: "Ambiguity fixture.",
                confidence: 0.8,
                requiredRuntimes: [],
                launchOptions: [],
                notes: [],
                lastVerifiedAt: nil
            )
        }
        let game = SteamGame(
            steamAppId: "998",
            name: "Duplicate",
            installDir: "Duplicate",
            libraryPath: "/tmp",
            manifestPath: "/tmp/appmanifest_998.acf",
            sizeOnDisk: 1,
            lastUpdated: nil
        )

        XCTAssertThrowsError(
            try CompatibilityService().diagnosticGuidanceRecipe(
                for: game,
                storedRecords: [
                    try CompatibilityRecipeRecordProjection.makeRecord(
                        from: recipe(id: "steam-998-a")
                    ),
                    try CompatibilityRecipeRecordProjection.makeRecord(
                        from: recipe(id: "steam-998-b")
                    )
                ],
                bundle: .main
            )
        ) { error in
            guard case CompatibilityServiceError.ambiguousSteamAppID("998") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRecordProjectionUpdateDoesNotPartiallyMutateWhenJSONEncodingFails() throws {
        let originalRecipe = CompatibilityRecipe(
            id: "steam-1",
            steamAppId: "1",
            name: "Original",
            supportStatus: "playable",
            beginnerSummary: "Original summary.",
            technicalSummary: "Original technical summary.",
            confidence: 0.8,
            requiredRuntimes: [.vcrun2022],
            launchOptions: ["-windowed"],
            notes: ["Original note"],
            lastVerifiedAt: Date(timeIntervalSince1970: 10)
        )
        let record = try CompatibilityRecipeRecordProjection.makeRecord(from: originalRecipe)
        let originalJSON = record.recipeJSON
        let originalVerifiedAt = record.lastVerifiedAt
        let invalidRecipe = CompatibilityRecipe(
            id: "steam-1",
            steamAppId: "1",
            name: "Partially Mutated",
            supportStatus: "partial",
            beginnerSummary: "Updated summary.",
            technicalSummary: "Updated technical summary.",
            confidence: .nan,
            requiredRuntimes: [.d3dx9],
            launchOptions: ["-force-d3d11"],
            notes: ["Updated note"],
            lastVerifiedAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertThrowsError(try CompatibilityRecipeRecordProjection.update(record, from: invalidRecipe)) { error in
            guard case CompatibilityRecipeRecordProjectionError.encodeFailed(let recipeId) = error else {
                return XCTFail("Expected encodeFailed, got \(error)")
            }
            XCTAssertEqual(recipeId, "steam-1")
        }
        XCTAssertEqual(record.steamAppId, "1")
        XCTAssertEqual(record.name, "Original")
        XCTAssertEqual(record.supportStatus, "playable")
        XCTAssertEqual(record.confidence, 0.8)
        XCTAssertEqual(record.recipeJSON, originalJSON)
        XCTAssertEqual(record.lastVerifiedAt, originalVerifiedAt)
    }

    func testRequiredRecipeLookupPropagatesBundledRecipeLoadFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ForgePlayCompatibilityBundle-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let resourceRoot = root.appending(path: "Test.bundle/Contents/Resources", directoryHint: .isDirectory)
        let recipeDirectory = resourceRoot.appending(path: "recipes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recipeDirectory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: recipeDirectory.appending(path: "steam-1.json"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.forgeplay.test.bundle</string>
        </dict>
        </plist>
        """.utf8).write(to: root.appending(path: "Test.bundle/Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: root.appending(path: "Test.bundle", directoryHint: .isDirectory)))
        let game = SteamGame(
            steamAppId: "1",
            name: "Broken Bundled Recipe",
            installDir: "Broken Bundled Recipe",
            libraryPath: "/tmp",
            manifestPath: "/tmp/appmanifest_1.acf",
            sizeOnDisk: 1,
            lastUpdated: nil
        )

        XCTAssertThrowsError(try CompatibilityService().requiredRecipe(for: game, bundle: bundle)) { error in
            guard case CompatibilityServiceError.decodeFailed(let url) = error else {
                return XCTFail("Expected decodeFailed, got \(error)")
            }
            XCTAssertEqual(url.lastPathComponent, "steam-1.json")
        }
    }

    private func recipeData(
        id: String,
        name: String,
        supportStatus: String = "playable",
        confidence: Double = 0.8,
        launchOptions: [String] = []
    ) throws -> Data {
        let recipe = CompatibilityRecipe(
            id: id,
            steamAppId: id.replacingOccurrences(of: "steam-", with: ""),
            name: name,
            supportStatus: supportStatus,
            beginnerSummary: "Runs with one runtime.",
            technicalSummary: "Test recipe.",
            confidence: confidence,
            requiredRuntimes: [.vcrun2022],
            launchOptions: launchOptions,
            notes: [],
            lastVerifiedAt: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(recipe)
    }

    private func recipeJSONString(
        id: String,
        name: String,
        supportStatus: String = "playable",
        confidence: Double = 0.8,
        launchOptions: [String] = []
    ) throws -> String {
        String(
            data: try recipeData(
                id: id,
                name: name,
                supportStatus: supportStatus,
                confidence: confidence,
                launchOptions: launchOptions
            ),
            encoding: .utf8
        ) ?? "{}"
    }
}
