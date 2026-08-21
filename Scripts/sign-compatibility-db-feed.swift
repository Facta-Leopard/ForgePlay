import CryptoKit
import Foundation

struct CompatibilityRecipe: Codable {
    var id: String
    var steamAppId: String?
    var name: String
    var supportStatus: String
    var beginnerSummary: String
    var technicalSummary: String
    var confidence: Double
    var requiredRuntimes: [String]
    var launchOptions: [String]
    var notes: [String]
    var lastVerifiedAt: Date?
}

struct CompatibilityDBSignedIndex: Codable {
    var payload: CompatibilityDBIndexPayload
    var signature: String
}

struct CompatibilityDBIndexPayload: Codable {
    var schemaVersion: Int
    var databaseVersion: Int
    var generatedAt: Date?
    var recipes: [CompatibilityDBRecipeDescriptor]
}

struct CompatibilityDBRecipeDescriptor: Codable {
    var id: String
    var url: URL
    var sha256: String
    var signature: String
}

struct ArgumentParser {
    private var values: [String: String] = [:]

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--"), index + 1 < arguments.count else {
                fail("invalid argument: \(argument)")
            }
            values[argument] = arguments[index + 1]
            index += 2
        }
    }

    func value(_ key: String) -> String {
        guard let value = values[key], !value.isEmpty else {
            fail("missing required argument: \(key)")
        }
        return value
    }

    func optionalValue(_ key: String) -> String? {
        values[key]
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL
}

func resourceValuesIfPresent(_ url: URL, keys: Set<URLResourceKey>, label: String) -> URLResourceValues? {
    do {
        return try url.resourceValues(forKeys: keys)
    } catch {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue {
            return nil
        }
        fail("could not inspect \(label): \(url.path). \(error.localizedDescription)")
    }
}

func requireRegularFile(_ url: URL, label: String) {
    let values: URLResourceValues
    do {
        values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .linkCountKey])
    } catch {
        fail("could not inspect \(label): \(url.path). \(error.localizedDescription)")
    }
    guard values.isRegularFile == true,
          values.isSymbolicLink != true else {
        fail("\(label) must be a non-symlink regular file: \(url.path)")
    }
    guard values.linkCount == 1 else {
        fail("\(label) must not be hardlinked: \(url.path)")
    }
}

func requirePrivateKeyFile(_ url: URL) {
    requireSafeDirectoryAncestorChain(for: url.deletingLastPathComponent(), label: "private key")
    let values: URLResourceValues
    do {
        values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .linkCountKey])
    } catch {
        fail("could not inspect private key: \(url.path). \(error.localizedDescription)")
    }
    guard values.isRegularFile == true,
          values.isSymbolicLink != true else {
        fail("private key must be a non-symlink regular file: \(url.path)")
    }
    guard values.linkCount == 1 else {
        fail("private key must not be hardlinked: \(url.path)")
    }

    let attributes: [FileAttributeKey: Any]
    do {
        attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch {
        fail("could not inspect private key permissions: \(url.path). \(error.localizedDescription)")
    }
    guard let permissions = attributes[.posixPermissions] as? NSNumber else {
        fail("could not read private key permissions: \(url.path)")
    }
    guard permissions.intValue & 0o077 == 0 else {
        fail("private key file permissions must not allow group or other access: \(url.path)")
    }
}

func requireNonSymlinkDirectory(_ url: URL, label: String) {
    let values: URLResourceValues
    do {
        values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    } catch {
        fail("could not inspect \(label): \(url.path). \(error.localizedDescription)")
    }
    guard values.isDirectory == true,
          values.isSymbolicLink != true else {
        fail("\(label) must be a non-symlink directory: \(url.path)")
    }
}

func requireSafeDirectoryAncestorChain(for directory: URL, label: String) {
    var current = directory.standardizedFileURL
    while current.path != "/" {
        if let values = resourceValuesIfPresent(
            current,
            keys: [.isDirectoryKey, .isSymbolicLinkKey],
            label: "\(label) parent path"
        ) {
            let permittedSystemAlias = current.path == "/tmp" || current.path == "/var"
            guard values.isSymbolicLink != true || permittedSystemAlias else {
                fail("\(label) parent path must contain only non-symlink directories: \(current.path)")
            }
            guard values.isSymbolicLink == true || values.isDirectory == true else {
                fail("\(label) parent path must contain only non-symlink directories: \(current.path)")
            }
        }
        let parent = current.deletingLastPathComponent()
        guard parent.path != current.path else {
            break
        }
        current = parent
    }
}

func ensureOutputDirectory(_ directory: URL, label: String) throws {
    requireSafeDirectoryAncestorChain(for: directory.deletingLastPathComponent(), label: label)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    requireNonSymlinkDirectory(directory, label: label)
}

@discardableResult
func prepareOutputFile(_ url: URL, label: String) -> Bool {
    guard let values = resourceValuesIfPresent(
        url,
        keys: [.isRegularFileKey, .isSymbolicLinkKey, .linkCountKey],
        label: label
    ) else {
        return false
    }
    guard values.isRegularFile == true,
          values.isSymbolicLink != true else {
        fail("\(label) must be a non-symlink regular file: \(url.path)")
    }
    guard values.linkCount == 1 else {
        fail("\(label) must not be hardlinked: \(url.path)")
    }
    return true
}

func readTextFile(_ url: URL, label: String) -> String {
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        fail("could not read \(label): \(url.path). \(error.localizedDescription)")
    }
}

func readDataFile(_ url: URL, label: String) -> Data {
    do {
        return try Data(contentsOf: url)
    } catch {
        fail("could not read \(label): \(url.path). \(error.localizedDescription)")
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func sign(_ data: Data, privateKey: P256.Signing.PrivateKey) -> String {
    do {
        return try privateKey.signature(for: data).derRepresentation.base64EncodedString()
    } catch {
        fail("could not sign compatibility DB payload: \(error.localizedDescription)")
    }
}

let sensitiveQueryItemNames: Set<String> = [
    "apikey",
    "accesstoken",
    "refreshtoken",
    "authtoken",
    "token",
    "secret",
    "password",
    "sessionid",
    "steamloginsecure"
]

func hasSensitiveQueryItem(_ components: URLComponents) -> Bool {
    guard let queryItems = components.queryItems else {
        return false
    }
    return queryItems.contains { item in
        let normalizedName = item.name
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        return sensitiveQueryItemNames.contains(normalizedName)
    }
}

func validatedBaseURL(_ value: String) -> URL {
    guard let url = URL(string: value),
          url.scheme?.lowercased() == "https",
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.host?.isEmpty == false,
          components.user == nil,
          components.password == nil,
          components.fragment == nil,
          !hasSensitiveQueryItem(components) else {
        fail("base URL must be HTTPS, include a host, and omit userinfo, fragment, and secret query parameters")
    }
    return url
}

func readPrivateKey(_ url: URL) -> P256.Signing.PrivateKey {
    requirePrivateKeyFile(url)
    let text = readTextFile(url, label: "private key")
    guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("private key file must contain a base64 P-256 signing private key raw representation")
    }
    do {
        return try P256.Signing.PrivateKey(rawRepresentation: data)
    } catch {
        fail("private key file is not a valid P-256 signing private key raw representation")
    }
}

func recipeFiles(in directory: URL) -> [URL] {
    requireNonSymlinkDirectory(directory, label: "recipes path")
    do {
        return try FileManager.default
            .contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
        fail("could not enumerate recipe directory: \(directory.path). \(error.localizedDescription)")
    }
}

func copyRecipe(_ source: URL, to outputRecipesDirectory: URL) throws {
    let destination = outputRecipesDirectory.appending(path: source.lastPathComponent, directoryHint: .notDirectory)
    if prepareOutputFile(destination, label: "recipe output") {
        try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
}

func verifyGeneratedFeed(
    index: CompatibilityDBSignedIndex,
    outputDirectory: URL,
    publicKey: P256.Signing.PublicKey,
    signingEncoder: JSONEncoder
) {
    guard let indexSignature = Data(base64Encoded: index.signature),
          let ecdsaIndexSignature = try? P256.Signing.ECDSASignature(derRepresentation: indexSignature),
          let payloadData = try? signingEncoder.encode(index.payload),
          publicKey.isValidSignature(ecdsaIndexSignature, for: payloadData) else {
        fail("generated index signature did not verify")
    }

    for descriptor in index.payload.recipes {
        let recipeURL = outputDirectory
            .appending(path: "recipes", directoryHint: .isDirectory)
            .appending(path: descriptor.url.lastPathComponent, directoryHint: .notDirectory)
        let recipeData = readDataFile(recipeURL, label: "generated recipe")
        guard sha256Hex(recipeData) == descriptor.sha256 else {
            fail("generated recipe checksum did not verify: \(descriptor.id)")
        }
        guard let signatureData = Data(base64Encoded: descriptor.signature),
              let ecdsaSignature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
              publicKey.isValidSignature(ecdsaSignature, for: recipeData) else {
            fail("generated recipe signature did not verify: \(descriptor.id)")
        }
    }
}

let arguments = ArgumentParser(Array(CommandLine.arguments.dropFirst()))
let recipesDirectory = fileURL(arguments.value("--recipes"))
let outputDirectory = fileURL(arguments.value("--output"))
let privateKey = readPrivateKey(fileURL(arguments.value("--private-key-file")))
let baseURL = validatedBaseURL(arguments.value("--base-url"))
guard let databaseVersion = Int(arguments.value("--database-version")), databaseVersion > 0 else {
    fail("database version must be a positive integer")
}

let generatedAt: Date
if let generatedAtValue = arguments.optionalValue("--generated-at") {
    guard let date = ISO8601DateFormatter().date(from: generatedAtValue) else {
        fail("generated-at must be an ISO-8601 date")
    }
    generatedAt = date
} else {
    generatedAt = Date()
}

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601

let signingEncoder = JSONEncoder()
signingEncoder.outputFormatting = [.sortedKeys]
signingEncoder.dateEncodingStrategy = .iso8601

let outputEncoder = JSONEncoder()
outputEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
outputEncoder.dateEncodingStrategy = .iso8601

let outputRecipesDirectory = outputDirectory.appending(path: "recipes", directoryHint: .isDirectory)

do {
    try ensureOutputDirectory(outputDirectory, label: "feed output directory")
    try ensureOutputDirectory(outputRecipesDirectory, label: "feed recipes output directory")
} catch {
    fail("could not create feed output directory: \(error.localizedDescription)")
}

var descriptors: [CompatibilityDBRecipeDescriptor] = []
for source in recipeFiles(in: recipesDirectory) {
    requireRegularFile(source, label: "recipe")
    let recipeData = readDataFile(source, label: "recipe")
    let recipe: CompatibilityRecipe
    do {
        recipe = try decoder.decode(CompatibilityRecipe.self, from: recipeData)
    } catch {
        fail("could not decode recipe \(source.lastPathComponent): \(error.localizedDescription)")
    }
    guard source.lastPathComponent == "\(recipe.id).json" else {
        fail("recipe filename must match recipe id: \(source.lastPathComponent) != \(recipe.id).json")
    }
    do {
        try copyRecipe(source, to: outputRecipesDirectory)
    } catch {
        fail("could not copy recipe \(source.lastPathComponent): \(error.localizedDescription)")
    }
    descriptors.append(
        CompatibilityDBRecipeDescriptor(
            id: recipe.id,
            url: baseURL
                .appending(path: "recipes", directoryHint: .isDirectory)
                .appending(path: source.lastPathComponent, directoryHint: .notDirectory),
            sha256: sha256Hex(recipeData),
            signature: sign(recipeData, privateKey: privateKey)
        )
    )
}

guard !descriptors.isEmpty else {
    fail("no recipe JSON files found in \(recipesDirectory.path)")
}

let payload = CompatibilityDBIndexPayload(
    schemaVersion: 1,
    databaseVersion: databaseVersion,
    generatedAt: generatedAt,
    recipes: descriptors
)
let payloadData: Data
do {
    payloadData = try signingEncoder.encode(payload)
} catch {
    fail("could not encode index payload for signing: \(error.localizedDescription)")
}
let index = CompatibilityDBSignedIndex(payload: payload, signature: sign(payloadData, privateKey: privateKey))

do {
    let indexOutput = outputDirectory.appending(path: "index.json", directoryHint: .notDirectory)
    let publicKeyOutput = outputDirectory.appending(path: "CompatibilityDBPublicKey.base64", directoryHint: .notDirectory)
    prepareOutputFile(indexOutput, label: "index output")
    prepareOutputFile(publicKeyOutput, label: "public key output")
    try outputEncoder
        .encode(index)
        .write(to: indexOutput, options: .atomic)
    try (privateKey.publicKey.rawRepresentation.base64EncodedString() + "\n")
        .write(
            to: publicKeyOutput,
            atomically: true,
            encoding: .utf8
        )
} catch {
    fail("could not write signed compatibility DB feed: \(error.localizedDescription)")
}

verifyGeneratedFeed(
    index: index,
    outputDirectory: outputDirectory,
    publicKey: privateKey.publicKey,
    signingEncoder: signingEncoder
)

print("Signed compatibility DB feed: \(outputDirectory.path)")
print("Recipes: \(descriptors.count)")
print("Public key: \(outputDirectory.appending(path: "CompatibilityDBPublicKey.base64").path)")
